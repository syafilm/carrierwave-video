require 'streamio-ffmpeg'
require 'carrierwave'
require 'carrierwave/video/ffmpeg_options'
require 'carrierwave/video/ffmpeg_theora'
require 'mini_exiftool'


module CarrierWave
  module Video
    extend ActiveSupport::Concern
    def self.ffmpeg2theora_binary=(bin)
      @ffmpeg2theora = bin
    end

    def self.ffmpeg2theora_binary
      @ffmpeg2theora.nil? ? 'ffmpeg2theora' : @ffmpeg2theora
    end

    module ClassMethods
      def encode_video(target_format, options={})
        process encode_video: [target_format, options]
      end

      def encode_ogv(opts={})
        process encode_ogv: [opts]
      end

    end

    def encode_ogv(opts)
      # move upload to local cache
      cache_stored_file! if !cached?

      tmp_path  = File.join( File.dirname(current_path), "tmpfile.ogv" )
      @options = CarrierWave::Video::FfmpegOptions.new('ogv', opts)

      with_transcoding_callbacks do
        transcoder = CarrierWave::Video::FfmpegTheora.new(current_path, tmp_path)
        transcoder.run(@options.logger(model))
        File.rename tmp_path, current_path
      end
    end

    def encode_video(format, opts = {})
      # Move upload to local cache
      cache_stored_file! unless cached?

      @options = CarrierWave::Video::FfmpegOptions.new(format, opts)
      tmp_path = File.join(File.dirname(current_path), "tmpfile.#{format}")
      file = FFMPEG::Movie.new(current_path)
      video = MiniExiftool.new(current_path)
      orientation = video.rotation.to_i
      # Resolution handling
      if [:same, :onethird, :half].include?(opts[:resolution])
        original_width = file.width
        original_height = file.height

        # Adjust for rotation
        if orientation == 90 || orientation == 270
          original_width, original_height = original_height, original_width
        end

        width, height = case opts[:resolution]
                        when :onethird
                          [(original_width / 3.0).floor, (original_height / 3.0).floor]
                        when :half
                          [(original_width / 2.0).floor, (original_height / 2.0).floor]
                        else
                          [original_width, original_height]
                        end

        # Ensure even dimensions (libx264 requires this)
        width  = [2, (width / 2) * 2].max
        height = [2, (height / 2) * 2].max

        @options.format_options[:resolution] = "#{width}x#{height}"
      end

      # Video bitrate
      if opts[:video_bitrate] == :same
        @options.format_options[:video_bitrate] = file.video_bitrate
      end

      yield(file, @options.format_options) if block_given?

      # Optional strict flag if needed
      @options.format_options[:custom] ||= []
      @options.format_options[:custom] += ['-strict', '-2']

      progress = @options.progress(model)

      with_transcoding_callbacks do
        if progress
          if @encoder_options.present?
            file.transcode(tmp_path, @options.format_params, @encoder_options) {
                |value| progress.call(value)
            }
          else
            file.transcode(tmp_path, @options.format_params) {
                |value| progress.call(value)
            }
          end
        else
          if @encoder_options.present?
            file.transcode(tmp_path, @options.format_params, @encoder_options)
          else
            file.transcode(tmp_path, @options.format_params)
          end
        end
        File.rename tmp_path, current_path
      end
    end

    private
      def with_trancoding_callbacks(&block)
        callbacks = @options.callbacks
        logger = @options.logger(model)
        begin
          send_callback(callbacks[:before_transcode])
          setup_logger
          block.call
          send_callback(callbacks[:after_transcode])
        rescue => e
          send_callback(callbacks[:rescue])

          if logger
            logger.error "#{e.class}: #{e.message}"
            e.backtrace.each do |b|
              logger.error b
            end
          end

          raise e

        ensure
          reset_logger
          send_callback(callbacks[:ensure])
        end
      end

      def send_callback(callback)
        model.send(callback, @options.format, @options.raw) if callback.present?
      end

      def setup_logger
        return unless @options.logger(model).present?
        @ffmpeg_logger = ::FFMPEG.logger
        ::FFMPEG.logger = @options.logger(model)
      end

      def reset_logger
        return unless @ffmpeg_logger
        ::FFMPEG.logger = @ffmpeg_logger
      end
  end
end
