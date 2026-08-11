# Shared App Store Connect field caps and the glyph allowlist.
#
# Required by BOTH `fastlane/Fastfile` (which fails a lane before it archives)
# and `Tools/check-metadata.rb` (which fails a pull request in seconds, on
# Linux, without Xcode). One copy so the two can never disagree about what
# App Store Connect accepts.
#
# Every cap is measured in CHARACTERS, which is what the API counts — this
# text is full of em dashes, bullets and arrows, so its byte length runs
# several hundred over its character length.
module MetadataLimits
  # App Store Connect rejects an over-long field mid-upload with the opaque
  # "An attribute value is too long. - /data/attributes/<field>", after both
  # platform archives are built. Hence the pre-flight.
  WHATS_NEW = 4000        # TestFlight What to Test (build-level)
  REVIEW_NOTES = 4000     # App Review / Beta App Review notes

  # Per-locale listing fields. `description` and `release_notes` are stored
  # per platform (`description_ios.txt` / `description_visionos.txt`) — see
  # docs/agents/release-and-metadata.md for why there is no shared file.
  LOCALIZED = {
    "name" => 30,
    "subtitle" => 30,
    "promotional_text" => 170,
    "keywords" => 100,
    "description" => 4000,
    "release_notes" => 4000,
    "beta_app_description" => 4000,
    "marketing_url" => 255,
    "privacy_url" => 255,
    "support_url" => 255,
  }.freeze

  # Non-ASCII characters App Store Connect is known to accept in this app's
  # copy. Anything else is refused by the checker rather than by the API:
  # 1.3.1 shipped ⟨…⟩ (U+27E8/27E9) in the TestFlight changelog and the
  # upload failed on a character the file looked fine with everywhere else.
  # Add a glyph here only after an upload has actually accepted it.
  ALLOWED_GLYPHS = {
    "—" => "em dash",
    "“" => "left double quote",
    "”" => "right double quote",
    "’" => "right single quote",
    "•" => "bullet",
    "…" => "ellipsis",
    "→" => "rightwards arrow",
    "−" => "minus sign (A− / A+)",
    "⌗" => "viewport tab glyph",
    "▤" => "file viewer tab glyph",
    "▸" => "forward glyph (File Viewer history)",
    "◂" => "back glyph (File Viewer history)",
  }.freeze
end
