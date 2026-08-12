#!/usr/bin/env ruby
# frozen_string_literal: true

# Format check for the TestFlight changelog and the App Store metadata.
#
#   ruby Tools/check-metadata.rb
#
# Deliberately dependency-free (no fastlane, no gems, no Xcode) so CI can run
# it on Linux in seconds on every push — the failures it catches are the ones
# that otherwise surface after two platform archives, as an opaque Spaceship
# error mid-upload. Caps and the glyph allowlist come from
# Tools/metadata_limits.rb, shared with fastlane/Fastfile.
#
# Rules, and why each one is here (docs/agents/release-and-metadata.md):
#   - every field fits its App Store Connect cap, measured in CHARACTERS
#   - no field is empty; deliver would push a blank listing field
#   - descriptions and release notes are PER PLATFORM; a shared
#     description.txt can put Vision Pro-only claims on the iOS listing
#   - text is valid UTF-8, LF-only, free of control characters and of
#     non-ASCII glyphs App Store Connect has not been proven to accept
#   - URLs are single-line https://

require_relative "metadata_limits"

ROOT = File.expand_path("..", __dir__)
METADATA = File.join(ROOT, "fastlane", "metadata")
WHATS_NEW = File.join(ROOT, "fastlane", "testflight-whats-new.txt")

# Files deliver reads per locale. Platform-split fields are listed under the
# base name they inherit their cap from.
LOCALIZED_FILES = %w[
  name subtitle promotional_text keywords beta_app_description
  description_ios description_visionos
  release_notes_ios release_notes_visionos
  marketing_url privacy_url support_url
].freeze

# A shared file here would silently override / mix the platform split.
FORBIDDEN_FILES = %w[description.txt release_notes.txt].freeze

URL_FILES = %w[marketing_url privacy_url support_url].freeze

@errors = []

def error(path, message)
  @errors << "#{path.sub("#{ROOT}/", "")}: #{message}"
end

def relative(path)
  path.sub("#{ROOT}/", "")
end

# The cap a file is measured against: `description_ios` is a `description`.
def field_for(basename)
  MetadataLimits::LOCALIZED.key?(basename) ? basename : basename.sub(/_(ios|visionos)\z/, "")
end

def read_text(path)
  body = File.binread(path)
  body.force_encoding(Encoding::UTF_8)
  unless body.valid_encoding?
    error(path, "is not valid UTF-8")
    return nil
  end
  if body.include?("\r")
    error(path, "has CRLF (or lone CR) line endings; App Store copy is LF-only")
    return nil
  end
  body
end

# Control characters and unvetted glyphs. Tabs are included: they survive into
# the listing as literal whitespace nobody sees in the editor.
def check_characters(path, body)
  body.each_char.with_index do |char, index|
    next if char == "\n"
    ord = char.ord
    next if ord >= 0x20 && ord < 0x7F
    next if MetadataLimits::ALLOWED_GLYPHS.key?(char)

    line = body[0, index].count("\n") + 1
    name = ord < 0x20 || ord == 0x7F ? "control character" : "character #{char}"
    error(
      path,
      "line #{line}: #{name} (U+%04X) is not allowed. Use ASCII, or add it to " \
      "MetadataLimits::ALLOWED_GLYPHS once an upload has accepted it." % ord,
    )
    break # one report per file is enough to act on
  end
end

def check_length(path, body, limit)
  length = body.strip.length
  return if length <= limit

  error(path, "is #{length} characters; App Store Connect allows #{limit}")
end

def check_file(path, limit)
  body = read_text(path)
  return if body.nil?

  if body.strip.empty?
    error(path, "is empty")
    return
  end
  check_characters(path, body)
  check_length(path, body, limit) if limit
  body
end

def check_url(path, body)
  return if body.nil?

  url = body.strip
  error(path, "must be a single line") if url.include?("\n")
  error(path, "must be an https:// URL (got #{url.lines.first.to_s.strip})") unless url.start_with?("https://")
end

def check_keywords(path, body)
  return if body.nil?

  keywords = body.strip
  error(path, "must not contain newlines; keywords are one comma-separated line") if keywords.include?("\n")
  error(path, "must not put a space after a comma — the space costs a keyword character") if keywords.match?(/,\s/)
  error(path, "has an empty keyword (double comma or a trailing comma)") if keywords.match?(/(\A|,),|,\z/)
end

def check_whats_new
  unless File.exist?(WHATS_NEW)
    error(WHATS_NEW, "is missing; every user-visible change appends to it (AGENTS.md)")
    return
  end
  check_file(WHATS_NEW, MetadataLimits::WHATS_NEW)
end

def locale_directories
  Dir.children(METADATA)
     .select { |name| File.directory?(File.join(METADATA, name)) }
     .grep(/\A[a-z]{2}(-[A-Z]{2})?\z/)
     .sort
end

def check_locales
  locales = locale_directories
  if locales.empty?
    error(METADATA, "has no locale directories (expected e.g. en-US/)")
    return
  end

  locales.each do |locale|
    dir = File.join(METADATA, locale)

    FORBIDDEN_FILES.each do |name|
      path = File.join(dir, name)
      next unless File.exist?(path)

      error(path, "must not exist: descriptions and release notes are per platform " \
                  "(#{name.sub(".txt", "")}_ios.txt / _visionos.txt)")
    end

    LOCALIZED_FILES.each do |basename|
      path = File.join(dir, "#{basename}.txt")
      unless File.exist?(path)
        error(path, "is missing (required for locale #{locale})")
        next
      end

      body = check_file(path, MetadataLimits::LOCALIZED[field_for(basename)])
      check_url(path, body) if URL_FILES.include?(basename)
      check_keywords(path, body) if basename == "keywords"
    end

    # Anything else in the directory is either a deliver field this check does
    # not know or a stray file deliver will happily upload.
    Dir.children(dir).grep(/\.txt\z/).sort.each do |name|
      basename = File.basename(name, ".txt")
      next if LOCALIZED_FILES.include?(basename) || FORBIDDEN_FILES.include?(name)

      error(File.join(dir, name), "is an unrecognized metadata file; add it to " \
                                  "LOCALIZED_FILES in Tools/check-metadata.rb or delete it")
    end
  end
end

# Only notes.txt has a cap worth pre-flighting; the rest are short strings and
# two of them are deliberately absent from git (see fastlane/SETUP.md).
def check_review_information
  path = File.join(METADATA, "review_information", "notes.txt")
  return unless File.exist?(path)

  check_file(path, MetadataLimits::REVIEW_NOTES)
end

def report_sizes
  paths = [WHATS_NEW] + Dir.glob(File.join(METADATA, "*", "*.txt")).sort
  puts "field                                                chars  limit"
  paths.each do |path|
    next unless File.exist?(path)

    body = File.binread(path).force_encoding(Encoding::UTF_8)
    next unless body.valid_encoding?

    limit =
      if path == WHATS_NEW
        MetadataLimits::WHATS_NEW
      elsif File.basename(File.dirname(path)) == "review_information"
        File.basename(path) == "notes.txt" ? MetadataLimits::REVIEW_NOTES : nil
      else
        MetadataLimits::LOCALIZED[field_for(File.basename(path, ".txt"))]
      end
    printf("%-50s %6d  %5s\n", relative(path), body.strip.length, limit || "-")
  end
end

check_whats_new
check_locales
check_review_information
report_sizes

if @errors.empty?
  puts "\nOK: #{relative(WHATS_NEW)} and #{relative(METADATA)} pass the format check."
  exit 0
end

warn "\n#{@errors.length} metadata problem#{"s" unless @errors.length == 1}:"
@errors.each { |message| warn "  - #{message}" }
warn "\nRules: docs/agents/release-and-metadata.md"
exit 1
