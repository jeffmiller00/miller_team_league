source "https://rubygems.org"

gem "jekyll", "~> 4.3"
gem "erb", "~> 4.0" # bundled gem in Ruby 3.4+, jekyll requires it explicitly now
gem "logger", "~> 1.6" # default gem removal announced for Ruby 4.0
# jekyll-sass-converter v3 uses dart-sass via sass-embedded
# sass-embedded gem provides the Dart Sass implementation
# Pin a reasonably recent version to avoid future breaking changes

gem "jekyll-sass-converter", "~> 3.0"
gem "sass-embedded", "~> 1.77"

group :development do
  gem "webrick", "~> 1.8" # required for Ruby 3.x jekyll serve
end
