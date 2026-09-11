require 'typhoeus'
require 'date'
require 'json'
require 'yaml'
require 'fileutils'

# Paths are resolved relative to this file so the script can be run from any
# working directory, not just _scripts/.
ROOT         = File.expand_path('..', __dir__)
DATA_FILE    = File.join(ROOT, '_data', 'nfl.json')
PICKS_FILE   = File.join(ROOT, '_data', 'index', 'nfl_picks.yml')
SUMMARY_FILE = File.join(ROOT, '_data', 'index', 'nfl_summary.yml')
ARCHIVE_DIR  = File.join(ROOT, '_data', 'archive')

TEAMS_URL  = 'https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams?limit=32'
TEAM_URL   = 'https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams/%s'
DEFAULT_PLAYERS = %i[jeff greg tim zach].freeze
CHART_WEEKS         = 10
REGULAR_SEASON_WEEKS = 18

# Run with --dry-run to print what would change without writing any file, and
# --no-fetch to rebuild the table and chart from the existing nfl.json.
DRY_RUN    = ARGV.include?('--dry-run')
SKIP_FETCH = ARGV.include?('--no-fetch')

def fetch_wins?; !SKIP_FETCH; end
def write_file?; !DRY_RUN; end

# The wins hash holds one cumulative snapshot per NFL week, keyed to that week's
# Monday, which is why this is run on Tuesdays after Monday Night Football.
def snapshot_date; Date.today.prev_day; end

def season_year(today = Date.today)
  today.month < 3 ? today.year - 1 : today.year
end

# NFL week 1 kicks off the Thursday after Labor Day (the first Monday in
# September), so the season start is derived rather than edited every year.
def week1_begins(year = season_year)
  labor_day = (Date.new(year, 9, 1)..Date.new(year, 9, 7)).find(&:monday?)
  labor_day + 3
end

def get_teams
  JSON.parse(File.read(DATA_FILE))
end

def chart_config
  @chart_config ||= File.exist?(SUMMARY_FILE) ? (YAML.load_file(SUMMARY_FILE) || {}) : {}
end

# Read the roster from the chart legend so that adding or dropping a brother
# only means editing nfl_summary.yml, and so each data series stays lined up
# with the colour it is drawn in.
def players
  @players ||= begin
    names = (chart_config['players'] || []).map { |player| player['name'].to_s.downcase.to_sym }
    names.empty? ? DEFAULT_PLAYERS : names
  end
end

def parse_team_name(combined_name)
  if combined_name.include?('Washington')
    location = combined_name.split(' ').first
    team_name = combined_name.sub(location, '').strip
  else
    team_name = combined_name.split(' ').last
    location = combined_name.sub(team_name, '').strip
  end
  [location, team_name]
end

def find_team(needle, haystack)
  return nil if haystack.nil? || haystack.empty?

  needle['full_name'] ||= needle['name']
  needle['location'], needle['name'] = parse_team_name(needle['name']) if needle['location'].nil?

  # nfl.json holds teams flat; the ESPN payload nests them under a "team" key.
  nested = !haystack.first['team'].nil?
  team_of = ->(t) { nested ? t['team'] : t }

  matches = haystack.select { |t| team_of.call(t)['location'] == needle['location'] && team_of.call(t)['name'] == needle['name'] }
  matches = haystack.select { |t| team_of.call(t)['name'] == needle['name'] }         if matches.size != 1
  matches = haystack.select { |t| team_of.call(t)['location'] == needle['location'] } if matches.size != 1

  matches.first
end

def win_streak(wins_by_date)
  wins_series = wins_by_date.sort_by { |date, _| date }.map { |_, wins| wins }
  return 0 if wins_series.size < 2

  if wins_series[-1] == wins_series[-2]
    # Negative streak: weeks since the last win.
    # TODO: This does not handle bye weeks correctly. A bye reads as a loss
    # because the wins hash alone cannot tell a bye from a defeat; fixing it
    # means also recording gamesPlayed per week.
    plateau = 0
    last_val = wins_series[-1]
    i = wins_series.size - 1
    while i >= 0 && wins_series[i] == last_val
      plateau += 1
      i -= 1
    end
    -(plateau - 1)
  else
    # Positive streak: consecutive +1 increments ending the series.
    len = 0
    i = wins_series.size - 1
    while i > 0 && wins_series[i] - wins_series[i - 1] == 1
      len += 1
      i -= 1
    end
    len
  end
end

def generate_team_table
  all_teams = get_teams
  player_picks = YAML.load(File.read(PICKS_FILE))

  player_picks.each do |player|
    # The "Undrafted" row carries no teams once every team has been drafted.
    next if player['teams'].nil? || player['teams'].empty?

    player['teams'].each do |team|
      truth_team = find_team(team, all_teams)
      abort "Could not match #{player['name']}'s pick #{team['name'].inspect} to a team in #{DATA_FILE}" if truth_team.nil?

      wins_by_date = truth_team['wins']
      abort "#{truth_team['name']} has no recorded wins in #{DATA_FILE}" if wins_by_date.nil? || wins_by_date.empty?

      team['wins']   = wins_by_date.values.max
      team['streak'] = win_streak(wins_by_date)
    end
  end

  if write_file?
    File.write(PICKS_FILE, player_picks.to_yaml)
  else
    puts player_picks.to_yaml
  end
end

def generate_summary_chart
  all_teams = get_teams
  week1begin = week1_begins
  weeks_elapsed = ((Date.today - week1begin) / 7).to_i + 1
  week_count = weeks_elapsed.clamp(1, REGULAR_SEASON_WEEKS)

  weekly_summary = (0...week_count).map do |i|
    week_begin = week1begin.next_day(7 * i)
    empty_week = players.to_h { |player| [player, 0] }
    # Cover all seven days so a snapshot is never dropped between buckets.
    empty_week.merge(weekNum: i + 1, dates: (week_begin..week_begin.next_day(6)))
  end

  drafters = all_teams.map { |team| team['drafted_by'].to_s.downcase }.reject(&:empty?).uniq
  unknown = drafters - players.map(&:to_s)
  unless unknown.empty?
    warn "Warning: #{unknown.join(', ')} drafted teams in nfl.json but are missing from the " \
         "chart legend in nfl_summary.yml, so their wins are left out of the summary chart."
  end

  all_teams.each do |team|
    next if team['drafted_by'].to_s.empty?
    player = team['drafted_by'].downcase.to_sym
    next unless players.include?(player)

    snapshots = team['wins'].map { |date, wins| [Date.parse(date), wins] }.sort_by(&:first)
    weekly_summary.each do |summary|
      # Wins are cumulative, so carry the latest total recorded by the end of
      # the week. Summing every snapshot in the week would multiply the season
      # total on a double run, and reading only that week's would drop a
      # missed one to zero.
      latest = snapshots.reverse_each.find { |date, _| date <= summary[:dates].last }
      next if latest.nil?
      summary[player] += latest.last
    end
  end

  all_summaries = players.map { |player| weekly_summary.map { |s| s[player] }.last(CHART_WEEKS) }

  chart = chart_config
  chart['data']   = all_summaries.to_s
  chart['labels'] = weekly_summary.last(CHART_WEEKS).map { |s| "Wk #{s[:weekNum]}" }

  if write_file?
    File.write(SUMMARY_FILE, chart.to_yaml)
  else
    puts chart.to_yaml
  end
end

def fetch_team_wins(team_id)
  response = Typhoeus.get(format(TEAM_URL, team_id), followlocation: true)
  return [nil, "HTTP #{response.code}"] unless response.success?

  items = JSON.parse(response.body).dig('team', 'record', 'items')
  return [nil, 'no record in payload'] if items.nil? || items.empty?

  total = items.find { |i| i['type'] == 'total' } || items.first
  stat = total['stats'].find { |s| s['name'] == 'wins' }
  return [nil, 'no wins stat in record'] if stat.nil?

  [stat['value'].to_i, nil]
rescue JSON::ParserError => e
  [nil, "unparseable response (#{e.message})"]
end

def fetch_all_wins
  response = Typhoeus.get(TEAMS_URL, followlocation: true)
  abort "ESPN teams request failed (HTTP #{response.code})" unless response.success?

  league = JSON.parse(response.body).dig('sports', 0, 'leagues', 0)
  truth_teams = league['teams']
  abort 'ESPN teams request returned no teams' if truth_teams.nil? || truth_teams.empty?
  puts "ESPN reports the #{league.dig('season', 'displayName')} season; recording wins as of #{snapshot_date}."

  all_teams = get_teams
  fetched = {}
  errors  = []

  all_teams.each do |team|
    truth_team = find_team(team, truth_teams)
    if truth_team.nil?
      errors << "#{team['location']} #{team['name']}: no matching ESPN team"
      next
    end

    wins, error = fetch_team_wins(truth_team['team']['id'])
    if error
      errors << "#{truth_team['team']['displayName']}: #{error}"
      next
    end

    fetched[team.object_id] = wins
    puts "#{truth_team['team']['displayName']} | #{wins}" unless write_file?
  end

  # Only commit a complete fetch, so a partial failure can never leave nfl.json
  # with some teams updated and others stale.
  unless errors.empty?
    abort "Aborting without writing #{DATA_FILE}; #{errors.size} of #{all_teams.size} teams failed:\n  " + errors.join("\n  ")
  end

  all_teams.each { |team| team['wins'][snapshot_date.to_s] = fetched[team.object_id] }

  if write_file?
    FileUtils.mkdir_p(ARCHIVE_DIR)
    FileUtils.copy(DATA_FILE, File.join(ARCHIVE_DIR, "nfl_#{Date.today}.json"))
    File.write(DATA_FILE, all_teams.to_json)
  else
    puts all_teams.to_json
  end
end

unless Date.today.tuesday?
  warn "Warning: today is #{Date.today.strftime('%A')}. Snapshots are keyed to the previous " \
       "day (#{snapshot_date}) and the season is scored one run per week, on Tuesday."
end

fetch_all_wins if fetch_wins?
generate_team_table
puts '---------------------------||-------------------------'
generate_summary_chart
