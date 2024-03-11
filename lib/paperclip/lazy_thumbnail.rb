# frozen_string_literal: true

module Paperclip
  class LazyThumbnail < Paperclip::Processor
    ALLOWED_FIELDS = %w(
      width
      height
      bands
      format
      coding
      interpretation
      icc-profile-data
      page-height
      n-pages
      loop
      delay
    ).freeze

    class PixelGeometryParser
      def self.parse(current_geometry, pixels)
        width  = Math.sqrt(pixels * (current_geometry.width.to_f / current_geometry.height)).round.to_i
        height = Math.sqrt(pixels * (current_geometry.height.to_f / current_geometry.width)).round.to_i

        Paperclip::Geometry.new(width, height)
      end
    end

    def initialize(file, options = {}, attachment = nil)
      super

      @crop = options[:geometry].to_s[-1, 1] == '#'
      @current_geometry = options.fetch(:file_geometry_parser, Geometry).from_file(@file)
      @target_geometry = options[:pixels] ? PixelGeometryParser.parse(@current_geometry, options[:pixels]) : options.fetch(:string_geometry_parser, Geometry).parse(options[:geometry].to_s)
      @format = options[:format]
      @current_format = File.extname(@file.path)
      @basename = File.basename(@file.path, @current_format)

      correct_current_format!
      correct_target_geometry!
    end

    def make
      return File.open(@file.path) unless needs_convert?

      dst = TempfileFactory.new.generate([@basename, @format ? ".#{@format}" : @current_format].join)

      transformed_image.write_to_file(dst.path, **save_options)

      dst
    end

    private

    def correct_target_geometry!
      min_side = [@current_geometry.width, @current_geometry.height].min.to_i
      @target_geometry = Paperclip::Geometry.new(min_side, min_side) if @target_geometry&.square? && min_side < @target_geometry.width
    end

    def correct_current_format!
      # If the attachment was uploaded through a base64 payload, the tempfile
      # will not have a file extension. We correct for this in the final file name.
      @current_format = File.extname(attachment.instance_read(:file_name)) if @current_format.blank?
    end

    def transformed_image
      # libvips has some optimizations for resizing an image on load. If we don't need to
      # resize the image, we have to load it a different way.
      if @target_geometry.nil?
        return Vips::Image.new_from_file(preserve_animation? ? "#{@file.path}[n=-1]" : @file.path, access: :sequential).copy.mutate do |mutable|
          (mutable.get_fields - ALLOWED_FIELDS).each do |field|
            mutable.remove!(field)
          end
        end
      end

      # libvips thumbnail operation does not work correctly on animated GIFs. If we need to
      # preserve the animation, we have to load all the frames and then manually crop
      # them to then reassemble.
      if preserve_animation?
        original_image = Vips::Image.new_from_file("#{@file.path}[n=-1]", access: :sequential)
        n_pages = original_image.get('n-pages')

        # The loaded image has each frame stacked on top of each other, therefore we must
        # account for this when giving the resizing constraint, otherwise the width will
        # always end up smaller than we want.
        resized_image = original_image.thumbnail_image(@target_geometry.width, height: @target_geometry.height * n_pages, size: :down).mutate do |mutable|
          (mutable.get_fields - ALLOWED_FIELDS).each do |field|
            mutable.remove!(field)
          end
        end

        # If we don't need to crop the image, then we're already done. Otherwise,
        # we need to manually crop each frame of the animation and reassemble them.
        return resized_image unless @crop

        page_height = resized_image.get('page-height')

        frames = (0...n_pages).map do |i|
          resized_image.crop(0, i * page_height, @target_geometry.width, @target_geometry.height)
        end

        Vips::Image.arrayjoin(frames, across: 1).copy.mutate do |mutable|
          mutable.set!('page-height', @target_geometry.height)
        end
      else
        Vips::Image.thumbnail(@file.path, @target_geometry.width, height: @target_geometry.height, **thumbnail_options).mutate do |mutable|
          (mutable.get_fields - ALLOWED_FIELDS).each do |field|
            mutable.remove!(field)
          end
        end
      end
    end

    def thumbnail_options
      @crop ? { crop: :centre } : { size: :down }
    end

    def save_options
      case @format
      when 'jpg'
        { Q: 90, interlace: true }
      else
        {}
      end
    end

    def preserve_animation?
      @format == 'gif' || (@format.blank? && @current_format == '.gif')
    end

    def needs_convert?
      needs_different_geometry? || needs_different_format? || needs_metadata_stripping?
    end

    def needs_different_geometry?
      (options[:geometry] && @current_geometry.width != @target_geometry.width && @current_geometry.height != @target_geometry.height) ||
        (options[:pixels] && @current_geometry.width * @current_geometry.height > options[:pixels])
    end

    def needs_different_format?
      @format.present? && @current_format != ".#{@format}"
    end

    def needs_metadata_stripping?
      @attachment.instance.respond_to?(:local?) && @attachment.instance.local?
    end
  end
end
