require 'typhoeus'
require 'nokogiri'
require 'date'
require 'json'
require 'yaml'
require 'pry'

DATA_FILE  = '../_data/nfl.json'
PICKS_FILE ='../_data/index/nfl_picks.yml'

def get_teams
  all_teams = File.read(DATA_FILE)
  JSON.parse(all_teams)
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

def find_team needle, haystack
  needle['full_name'] ||= needle['name']
  needle['location'], needle['name'] = parse_team_name(needle['name']) if needle['location'].nil?
  needle['location'], needle['name'] = parse_team_name(needle['name']) if needle['location'].nil?
  begin
  if haystack.first['team'].nil?
    truth_team = haystack.select{ |t| t['location'] == needle['location'] && t['name'] == needle['name'] }
    truth_team = haystack.select{ |t| t['name'] == needle['name'] } if (truth_team.nil? || truth_team.empty? || truth_team.size > 1)
    truth_team = haystack.select{ |t| t['location'] == needle['location'] } if (truth_team.nil? || truth_team.empty? || truth_team.size > 1)
  else
    truth_team = haystack.select{ |t| t['team']['location'] == needle['location'] && t['team']['name'] == needle['name'] }
    truth_team = haystack.select{ |t| t['team']['name'] == needle['name'] } if (truth_team.nil? || truth_team.empty? || truth_team.size > 1)
    truth_team = haystack.select{ |t| t['team']['location'] == needle['location'] } if (truth_team.nil? || truth_team.empty? || truth_team.size > 1)
  end
  rescue
    binding.pry
  end

  truth_team.first
end

def generate_team_table
  all_teams = get_teams
  player_picks = YAML.load(File.read(PICKS_FILE))

  player_picks.each do |player|
    player['teams'].each do |team|
      truth_team = find_team team, all_teams
      begin
        team['wins'] = truth_team['wins'].map{ |wins_on| wins_on[1] }.max
      rescue
      binding.pry
      end
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

EMPTY_WEEK = {jeff: 0, greg: 0, tim: 0, zach: 0, mike: 0}
CURRENT_NFL_WEEK = 7

def generate_summary_chart
  all_teams = get_teams
  weeklySummary = []
  week1begin = Date.parse('2021-09-09')
  week1end   = Date.parse('2021-09-13')
  CURRENT_NFL_WEEK.times do |i|
    weeklySummary[i] = EMPTY_WEEK.dup
    weekBegin = week1begin.next_day(7*i)
    weekEnd   = week1end.next_day(7*i)
    weeklySummary[i][:weekNum] = i+1
    weeklySummary[i][:dates] = (weekBegin..weekEnd)
  end

  all_teams.each do |team|
    next if team['drafted_by'].empty?
    brother = team['drafted_by'].downcase
    team['wins'].each do |date, wins|
      weeklySummary.each do |summary|
        if summary[:dates].include?(Date.parse(date))
          summary[brother.to_sym] += wins
        end
      end
    end
  end

  allSummaries = []
  allSummaries << weeklySummary.map{ |summary| summary[:jeff] }.last(10)
  allSummaries << weeklySummary.map{ |summary| summary[:greg] }.last(10)
  allSummaries << weeklySummary.map{ |summary| summary[:tim] }.last(10)
  allSummaries << weeklySummary.map{ |summary| summary[:zach] }.last(10)
  allSummaries << weeklySummary.map{ |summary| summary[:mike] }.last(10)
  puts allSummaries.to_s
end

def fetch_wins?; true; end;
def write_file?; true; end;

if fetch_wins?
  response = Typhoeus.get('http://site.api.espn.com/apis/site/v2/sports/football/nfl/teams', followlocation: true)
  truth_teams = JSON.parse(response.body)['sports'].first['leagues'].first['teams']
  response = Typhoeus.get('http://site.api.espn.com/apis/site/v2/sports/football/nfl/teams?page=2', followlocation: true)
  truth_teams = truth_teams + JSON.parse(response.body)['sports'].first['leagues'].first['teams']

  all_teams = JSON.parse(File.read(DATA_FILE))



  all_teams.each do |team|
    truth_team = find_team(team, truth_teams)
    # binding.pry
    # May need to adjust this after preseason.
    wins = truth_team['team']['record']['items'].first['stats'].find{|s| s['name'] == 'wins'}['value'].to_i
    puts "#{truth_team['team']['displayName']} | #{wins}" unless write_file?

    team['wins'][Date.today.prev_day.to_s] = wins
  end

  if write_file?
    FileUtils.copy(DATA_FILE, "../_data/archive/nfl_#{Date.today}.json")
    File.open(DATA_FILE,"w") do |f|
      f.write(all_teams.to_json)
    end
  else
    puts all_teams.to_json
  end
end

generate_team_table
puts '---------------------------||-------------------------'
generate_summary_chart