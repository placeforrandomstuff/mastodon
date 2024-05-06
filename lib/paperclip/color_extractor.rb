# frozen_string_literal: true

require 'mime/types/columnar'

module Paperclip
  class ColorExtractor < Paperclip::Processor
    MIN_CONTRAST        = 3.0
    ACCENT_MIN_CONTRAST = 2.0
    FREQUENCY_THRESHOLD = 0.01
    BINS = 10

    def make
      image = Vips::Image.new_from_file(@file.path)

      edge_image = begin
        transparent = Vips::Image.black(image.width * 0.75, image.height * 0.75)
        image.insert(transparent, (image.width * 0.25) / 2, (image.height * 0.25) / 2)
      end

      background_palette = palette_from_image(edge_image)
      foreground_palette = palette_from_image(image)

      background_color   = background_palette.first || foreground_palette.first
      foreground_colors  = []

      return @file if background_color.nil?

      max_distance       = 0
      max_distance_color = nil

      foreground_palette.each do |color|
        distance = ColorDiff.between(background_color, color)
        contrast = w3c_contrast(background_color, color)

        if distance > max_distance && contrast >= ACCENT_MIN_CONTRAST
          max_distance = distance
          max_distance_color = color
        end
      end

      foreground_colors << max_distance_color unless max_distance_color.nil?

      max_distance       = 0
      max_distance_color = nil

      foreground_palette.each do |color|
        distance = ColorDiff.between(background_color, color)
        contrast = w3c_contrast(background_color, color)

        if distance > max_distance && contrast >= MIN_CONTRAST && !foreground_colors.include?(color)
          max_distance = distance
          max_distance_color = color
        end
      end

      foreground_colors << max_distance_color unless max_distance_color.nil?

      # If we don't have enough colors for accent and foreground, generate
      # new ones by manipulating the background color
      (2 - foreground_colors.size).times do |i|
        foreground_colors << lighten_or_darken(background_color, 35 + (i * 15))
      end

      # We want the color with the highest contrast to background to be the foreground one,
      # and the one with the highest saturation to be the accent one
      foreground_color = foreground_colors.max_by { |rgb| w3c_contrast(background_color, rgb) }
      accent_color     = foreground_colors.max_by { |rgb| rgb_to_hsl(rgb.r, rgb.g, rgb.b)[1] }

      meta = {
        colors: {
          background: rgb_to_hex(background_color),
          foreground: rgb_to_hex(foreground_color),
          accent: rgb_to_hex(accent_color),
        },
      }

      attachment.instance.file.instance_write(:meta, (attachment.instance.file.instance_read(:meta) || {}).merge(meta))

      @file
    end

    private

    def palette_from_image(image)
      histogram = image.hist_find_ndim(bins: BINS)
      _, colors = histogram.max(size: 10, out_array: true, x_array: true, y_array: true)

      colors['out_array'].map.with_index do |v, i|
        x = colors['x_array'][i]
        y = colors['y_array'][i]

        rgb_from_xyv(histogram, x, y, v)
      end
    end

    # rubocop:disable Naming/MethodParameterName
    def rgb_from_xyv(image, x, y, v)
      pixel = image.getpoint(x, y)
      z = pixel.find_index(v)
      r = (x + 0.5) * 256 / BINS
      g = (y + 0.5) * 256 / BINS
      b = (z + 0.5) * 256 / BINS
      ColorDiff::Color::RGB.new(r, g, b)
    end

    def w3c_contrast(color1, color2)
      luminance1 = (color1.to_xyz.y * 0.01) + 0.05
      luminance2 = (color2.to_xyz.y * 0.01) + 0.05

      if luminance1 > luminance2
        luminance1 / luminance2
      else
        luminance2 / luminance1
      end
    end

    def rgb_to_hsl(r, g, b)
      r /= 255.0
      g /= 255.0
      b /= 255.0
      max = [r, g, b].max
      min = [r, g, b].min
      h = (max + min) / 2.0
      s = (max + min) / 2.0
      l = (max + min) / 2.0

      if max == min
        h = 0
        s = 0 # achromatic
      else
        d = max - min
        s = l >= 0.5 ? d / (2.0 - max - min) : d / (max + min)

        case max
        when r
          h = ((g - b) / d) + (g < b ? 6.0 : 0)
        when g
          h = ((b - r) / d) + 2.0
        when b
          h = ((r - g) / d) + 4.0
        end

        h /= 6.0
      end

      [(h * 360).round, (s * 100).round, (l * 100).round]
    end

    def hue_to_rgb(p, q, t)
      t += 1 if t.negative?
      t -= 1 if t > 1

      return (p + ((q - p) * 6 * t)) if t < 1 / 6.0
      return q if t < 1 / 2.0
      return (p + ((q - p) * ((2 / 3.0) - t) * 6)) if t < 2 / 3.0

      p
    end

    def hsl_to_rgb(h, s, l)
      h /= 360.0
      s /= 100.0
      l /= 100.0

      r = 0.0
      g = 0.0
      b = 0.0

      if s.zero?
        r = l.to_f
        g = l.to_f
        b = l.to_f # achromatic
      else
        q = l < 0.5 ? l * (s + 1) : l + s - (l * s)
        p = (2 * l) - q
        r = hue_to_rgb(p, q, h + (1 / 3.0))
        g = hue_to_rgb(p, q, h)
        b = hue_to_rgb(p, q, h - (1 / 3.0))
      end

      [(r * 255).round, (g * 255).round, (b * 255).round]
    end
    # rubocop:enable Naming/MethodParameterName

    def lighten_or_darken(color, by)
      hue, saturation, light = rgb_to_hsl(color.r, color.g, color.b)

      light = if light < 50
                [100, light + by].min
              else
                [0, light - by].max
              end

      ColorDiff::Color::RGB.new(*hsl_to_rgb(hue, saturation, light))
    end

    def rgb_to_hex(rgb)
      format('#%02x%02x%02x', rgb.r, rgb.g, rgb.b)
    end
  end
end
