require 'typhoeus'
require 'json'
require 'yaml'
require 'date'
require 'pry'

DATA_FILE  = '../_data/nba.json'
PICKS_FILE = '../_data/index/nba_picks.yml'
def fetch_wins?; true; end;
def write_file?; true; end;


def get_teams
  all_teams = File.read(DATA_FILE)
  JSON.parse(all_teams)
end

def generate_team_table
  all_teams = get_teams
  player_picks = YAML.load(File.read(PICKS_FILE))

  player_picks.each do |player|
    player['teams'].each do |team|
      truth_team = all_teams.find{ |team_hash| team_hash['name'].split.last == team['name'].split.last }
      team['wins'] = truth_team['wins'].map{ |wins_on| wins_on[1] }.max
    end
  end

  if write_file?
    File.open(PICKS_FILE,"w") do |f|
      f.write(player_picks.to_yaml)
    end
  else
    puts player_picks.to_yaml
  end
end

EMPTY_WEEK = {jeff: 0, greg: 0, tim: 0, zach: 0}

def generate_summary_chart
  all_teams = get_teams
  weeklySummary = {}

  all_teams.each do |team|
    next if team['drafted_by'].empty?
    brother = team['drafted_by'].downcase
    team['wins'].each do |date, wins|
      weeklySummary[date.to_s] = EMPTY_WEEK.dup if weeklySummary[date].nil?
      weeklySummary[date.to_s][brother.to_sym] = 0 if weeklySummary[date][brother.to_sym].nil?
      weeklySummary[date.to_s][brother.to_sym] += wins
    end
  end

  allSummaries = []
  allSummaries << weeklySummary.map{ |summary| summary[1][:jeff] }
  allSummaries << weeklySummary.map{ |summary| summary[1][:greg] }
  allSummaries << weeklySummary.map{ |summary| summary[1][:tim] }
  allSummaries << weeklySummary.map{ |summary| summary[1][:zach] }
  puts allSummaries.to_s
end

if fetch_wins?
=begin
  request = HTTPI::Request.new
  request.url = ''
  # request.query = { Season: '2015-16',
  #                   SeasonType: 'Regular%20Season'}
  response = HTTPI.get(request)
=end
  nba_api_url = 'https://stats.nba.com/stats/leaguestandingsv3?LeagueID=00&Season=2022-23&SeasonType=Regular+Season&SeasonYear='
  STATS_HEADERS = {
      'Host' => 'stats.nba.com',
      'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:72.0) Gecko/20100101 Firefox/72.0',
      'Accept' => 'application/json, text/plain, */*',
      'Accept-Language' => 'en-US,en;q=0.5',
      'Accept-Encoding' => 'json',
      'x-nba-stats-origin' => 'stats',
      'x-nba-stats-token' => 'true',
      'Connection' => 'keep-alive',
      'Referer' => 'https://stats.nba.com/',
      'Pragma' => 'no-cache',
      'Cache-Control' => 'no-cache',
  }
  response = Typhoeus.get(nba_api_url, headers: STATS_HEADERS, timeout: 5)
  truth_teams = JSON.parse(response.body)
  truth_teams = truth_teams['resultSets'].first['rowSet']

  all_teams = JSON.parse(File.read(DATA_FILE))

  all_teams.each do |team|
    truth_team = truth_teams.select{|t| t[3] == team['location'] }.first
    binding.pry if truth_team.nil? || truth_team.empty?

    team['wins'][Date.today.prev_day.to_s] = truth_team[13].to_i
  end

  if write_file?
    FileUtils.copy(DATA_FILE, "../_data/archive/nba_#{Date.today}.json")
    File.open(DATA_FILE,"w") do |f|
      f.write(all_teams.to_json)
    end
  end
end

generate_team_table
puts '---------------------------||-------------------------'
generate_summary_chart