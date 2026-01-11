# frozen_string_literal: true

require "uri"
require "aws-sdk-s3"
require_relative "../ls"

module S3
  module Ls
    class CLI
      USAGE = <<~USAGE.chomp
      Usage:
        s3-ls s3://bucket[/prefix]
      USAGE

      def self.start(argv)
        new(argv).start
      end

      def initialize(argv)
        @argv = argv.dup
      end

      def start
        client = Aws::S3::Client.new

        if @argv.empty?
          list_buckets(client)
        else
          uri = @argv.shift
          bucket, prefix = parse_s3_uri(uri)
          list_objects(client, bucket, prefix)
        end
      rescue S3::Ls::Error => e
        $stderr.puts "s3-ls: #{e.message}"
        exit 1
      rescue StandardError => e
        $stderr.puts "s3-ls: #{e.class}: #{e.message}"
        exit 1
      end

      private

      def list_objects(client, bucket, prefix)
        client.list_objects_v2(bucket: bucket, prefix: prefix).each_page do |page|
          page.contents.each do |object|
            $stdout.puts "s3://#{bucket}/#{object.key}"
          end
        end
      end

      def list_buckets(client)
        client.list_buckets.buckets.each do |bucket|
          $stdout.puts "s3://#{bucket.name}"
        end
      end

      def parse_s3_uri(input)
        uri = URI.parse(input)
        raise S3::Ls::Error, "invalid s3 uri: #{input}" unless uri.scheme == "s3"
        raise S3::Ls::Error, "missing bucket in s3 uri: #{input}" if uri.host.to_s.empty?

        bucket = uri.host
        prefix = uri.path
        prefix = prefix.sub(%r{\A/}, "")
        prefix = nil if prefix.empty?
        [bucket, prefix]
      rescue URI::InvalidURIError
        raise S3::Ls::Error, "invalid s3 uri: #{input}"
      end
    end
  end
end
