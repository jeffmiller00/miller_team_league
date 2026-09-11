source "https://rubygems.org"

gem "jekyll", "~> 4.3"
gem "erb", "~> 4.0" # bundled gem in Ruby 3.4+, jekyll requires it explicitly now
gem "logger", "~> 1.6" # default gem removal announced for Ruby 4.0
# jekyll-sass-converter v3 uses dart-sass via sass-embedded
# sass-embedded gem provides the Dart Sass implementation
# Pin a reasonably recent version to avoid future breaking changes

gem "jekyll-sass-converter", "~> 3.0"
gem "sass-embedded", "~> 1.77"

# _scripts/fetch_nfl_wins.rb and _scripts/fetch_nba_wins.rb pull standings from
# the ESPN and NBA stats APIs. Kept in their own group so CI can install the
# fetchers without the site's development tooling.
group :scripts do
  gem "typhoeus", "~> 1.4"
end

group :development do
  gem "webrick", "~> 1.8" # required for Ruby 3.x jekyll serve
  gem "pry", "~> 0.14" # fetch_nba_wins.rb still drops into a session on an unmatched team
end
