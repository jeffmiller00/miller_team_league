require 'typhoeus'
require 'date'
require 'json'
require 'yaml'
require 'fileutils'

# Paths are resolved relative to this file so the script can be run from any
# working directory, not just _scripts/.
ROOT         = File.expand_path('..', __dir__)
DATA_FILE    = File.join(ROOT, '_data', 'nba.json')
PICKS_FILE   = File.join(ROOT, '_data', 'index', 'nba_picks.yml')
SUMMARY_FILE = File.join(ROOT, '_data', 'index', 'nba_summary.yml')
ARCHIVE_DIR  = File.join(ROOT, '_data', 'archive')

# stats.nba.com throttles and blocks cloud IP ranges (including GitHub's
# runners), so standings come from ESPN, as they do for the NFL.
STANDINGS_URL   = 'https://site.api.espn.com/apis/v2/sports/basketball/nba/standings'
FETCH_ATTEMPTS  = 3
DEFAULT_PLAYERS = %i[jeff greg tim zach].freeze
CHART_POINTS    = 10

# The NBA Cup final is not counted in the standings, so its winner is credited
# one extra win here. Set to the team name (e.g. 'Knicks') once it's decided.
NBA_CUP_WINNER = nil

# Run with --dry-run to print what would change without writing any file, and
# --no-fetch to rebuild the table and chart from the existing nba.json.
DRY_RUN    = ARGV.include?('--dry-run')
SKIP_FETCH = ARGV.include?('--no-fetch')

def fetch_wins?; !SKIP_FETCH; end
def write_file?; !DRY_RUN; end

# Each snapshot holds the wins through the previous day's games.
def snapshot_date; Date.today.prev_day; end

def get_teams
  JSON.parse(File.read(DATA_FILE))
end

def chart_config
  @chart_config ||= File.exist?(SUMMARY_FILE) ? (YAML.load_file(SUMMARY_FILE) || {}) : {}
end

# Read the roster from the chart legend so each data series stays lined up
# with the colour it is drawn in.
def players
  @players ||= begin
    names = (chart_config['players'] || []).map { |player| player['name'].to_s.downcase.to_sym }
    names.empty? ? DEFAULT_PLAYERS : names
  end
end

def generate_team_table
  all_teams = get_teams
  player_picks = YAML.load(File.read(PICKS_FILE))

  player_picks.each do |player|
    next if player['teams'].nil? || player['teams'].empty?

    player['teams'].each do |team|
      truth_team = all_teams.find { |team_hash| team_hash['name'].split.last == team['name'].split.last }
      abort "Could not match #{player['name']}'s pick #{team['name'].inspect} to a team in #{DATA_FILE}" if truth_team.nil?

      wins_by_date = truth_team['wins']
      abort "#{truth_team['name']} has no recorded wins in #{DATA_FILE}" if wins_by_date.nil? || wins_by_date.empty?

      team['wins'] = wins_by_date.values.max
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
  dates = all_teams.flat_map { |team| team['wins'].keys }.uniq.map { |date| Date.parse(date) }.sort

  drafters = all_teams.map { |team| team['drafted_by'].to_s.downcase }.reject(&:empty?).uniq
  unknown = drafters - players.map(&:to_s)
  unless unknown.empty?
    warn "Warning: #{unknown.join(', ')} drafted teams in nba.json but are missing from the " \
         "chart legend in nba_summary.yml, so their wins are left out of the summary chart."
  end

  totals = dates.to_h { |date| [date, players.to_h { |player| [player, 0] }] }

  all_teams.each do |team|
    next if team['drafted_by'].to_s.empty?
    player = team['drafted_by'].downcase.to_sym
    next unless players.include?(player)

    snapshots = team['wins'].map { |date, wins| [Date.parse(date), wins] }.sort_by(&:first)
    dates.each do |date|
      # Wins are cumulative, so a team missing a snapshot carries its latest total.
      latest = snapshots.reverse_each.find { |snapshot_on, _| snapshot_on <= date }
      totals[date][player] += latest.last unless latest.nil?
    end
  end

  chart_dates = dates.last(CHART_POINTS)
  chart = chart_config
  chart['labels'] = chart_dates.map { |date| date.strftime('%-m.%-d') }
  chart['data']   = players.map { |player| chart_dates.map { |date| totals[date][player] } }.to_s

  if write_file?
    File.write(SUMMARY_FILE, chart.to_yaml)
  else
    puts chart.to_yaml
  end
end

def fetch_standings
  last_error = nil
  FETCH_ATTEMPTS.times do |attempt|
    sleep(10 * attempt) if attempt > 0
    response = Typhoeus.get(STANDINGS_URL, followlocation: true, timeout: 30)
    unless response.success?
      last_error = response.timed_out? ? 'timed out' : "HTTP #{response.code}"
      warn "ESPN standings request failed (#{last_error}), attempt #{attempt + 1} of #{FETCH_ATTEMPTS}"
      next
    end

    begin
      return JSON.parse(response.body)
    rescue JSON::ParserError => e
      last_error = "unparseable response (#{e.message})"
      warn "ESPN standings request returned an #{last_error}, attempt #{attempt + 1} of #{FETCH_ATTEMPTS}"
    end
  end
  abort "ESPN standings request failed after #{FETCH_ATTEMPTS} attempts: #{last_error}"
end

def fetch_all_wins
  standings = fetch_standings
  entries = (standings['children'] || []).flat_map { |conference| conference.dig('standings', 'entries') || [] }
  abort 'ESPN standings returned no teams' if entries.empty?
  puts "ESPN reports the #{standings.dig('children', 0, 'standings', 'seasonDisplayName') || standings.dig('season', 'displayName')} " \
       "season; recording wins as of #{snapshot_date}."

  all_teams = get_teams
  fetched = {}
  errors  = []

  all_teams.each do |team|
    entry = entries.find { |e| e['team']['location'] == team['location'] && e['team']['name'] == team['name'] }
    if entry.nil?
      errors << "#{team['location']} #{team['name']}: no matching ESPN team"
      next
    end

    wins = entry['stats'].find { |stat| stat['name'] == 'wins' }&.dig('value')
    if wins.nil?
      errors << "#{entry['team']['displayName']}: no wins stat in standings"
      next
    end

    cup_win = team['name'] == NBA_CUP_WINNER ? 1 : 0
    fetched[team.object_id] = wins.to_i + cup_win
    puts "#{entry['team']['displayName']} | #{fetched[team.object_id]}" unless write_file?
  end

  # Only commit a complete fetch, so a partial failure can never leave nba.json
  # with some teams updated and others stale.
  unless errors.empty?
    abort "Aborting without writing #{DATA_FILE}; #{errors.size} of #{all_teams.size} teams failed:\n  " + errors.join("\n  ")
  end

  all_teams.each { |team| team['wins'][snapshot_date.to_s] = fetched[team.object_id] }

  if write_file?
    FileUtils.mkdir_p(ARCHIVE_DIR)
    FileUtils.copy(DATA_FILE, File.join(ARCHIVE_DIR, "nba_#{Date.today}.json"))
    File.write(DATA_FILE, all_teams.to_json)
  else
    puts all_teams.to_json
  end
end

fetch_all_wins if fetch_wins?
generate_team_table
puts '---------------------------||-------------------------'
generate_summary_chart
