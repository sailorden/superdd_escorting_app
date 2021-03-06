require 'sinatra'
require 'haml'
require 'parse-ruby-client'
require 'faraday'
require 'faraday_middleware'

#SHIRASETE_BASE_URL = 'http://beta.shirasete.jp/projects/56/issues.json'
SHIRASETE_BASE_URL = 'http://beta.shirasete.jp/'
SHIRASETE_PROJECT_ID = 56

SHIRASETE_API_KEY = ENV['SHIRASETE_API_KEY']
PARSE_APPLICATION_ID = ENV['PARSE_APPLICATION_ID']
PARSE_API_KEY = ENV['PARSE_API_KEY']

CUSTOM_FIELD_IDS = {
  :identifier => 10,
  :published => 11,
  :action => 12,
  :way => 13,
  :discussion => 14
}

USERS = {
  109 => 'A',
  110 => 'B',
  111 => 'C',
  112 => 'D',
  113 => 'E',
  114 => 'F'
}

Parse.init(:application_id => PARSE_APPLICATION_ID, :api_key => PARSE_API_KEY)

class User
  attr_reader :id, :name

  def self.all
    users = []
    USERS.each do |key, value|
      users << User.new(key, value)
    end
    return users
  end

  def self.find(id)
    id = id.to_i
    return User.new(id, USERS[id])
  end

  def initialize(id, name)
    @id = id
    @name = name
  end
end

class Task
  @@get_conn = Faraday.new(:url => SHIRASETE_BASE_URL) do |faraday|
    faraday.adapter Faraday.default_adapter
    faraday.response :logger
    faraday.response :json
  end

  @@put_conn = Faraday.new(:url => SHIRASETE_BASE_URL) do |faraday|
    faraday.adapter Faraday.default_adapter
    faraday.response :logger
    #faraday.response :json
  end

  attr_reader :id, :subject, :identifier, :published, :action, :way, :discussion, :assigned_to_id

  def self.all(user, state)
    request_params = {
      :key => SHIRASETE_API_KEY,
      :assigned_to_id => user.id
    }
    if state == 'published'
      request_params[:status_id] = 'open'
      request_params[:cf_11] = 1
      request_params[:sort] = 'cf_8:desc'
    elsif state == 'skipped'
      request_params[:status_id] = 'closed'
      request_params[:sort] = 'cf_8:desc'
    else
      request_params[:status_id] = 'open'
      request_params[:cf_11] = 0
      request_params[:sort] = 'cf_8:asc'
    end
    response = @@get_conn.get "/projects/#{SHIRASETE_PROJECT_ID}/issues.json", request_params
    body = response.body
    issues = body['issues']
    tasks = []
    issues.each do |issue|
      tasks << Task.new(issue)
    end
    return tasks
  end

  def self.find(id)
    id = id.to_i
    response = @@get_conn.get "/issues/#{id}.json", {:key => SHIRASETE_API_KEY}
    body = response.body
    issue = body['issue']
    return Task.new(issue)
  end

  def initialize(issue)
    @id = issue['id']
    @subject = issue['subject']
    if assigned_to = issue['assigned_to']
      @assigned_to_id = assigned_to['id']
    end
    custom_fields = issue['custom_fields']
    custom_fields.each do |custom_field|
      id = custom_field['id']
      value = custom_field['value']
      case id
      when CUSTOM_FIELD_IDS[:identifier] then
        @identifier = value
      when CUSTOM_FIELD_IDS[:published] then
        if value.to_i == 1
          @published = true
        else
          @published = false
        end
      when CUSTOM_FIELD_IDS[:action] then
        @action = value
      when CUSTOM_FIELD_IDS[:way] then
        @way = value
      when CUSTOM_FIELD_IDS[:discussion] then
        @discussion = value
      end
    end
  end

  def publish
    response = @@put_conn.put do |req|
      req.url "/issues/#{@id}.json"
      req.headers['Content-Type'] = 'application/json'
      #req.headers['X-Redmine-API-Key'] = SHIRASETE_API_KEY
      req.body = { 
        :issue => {
          :custom_fields => [
            {:id => 11, :value => "1"}
          ]
        },
        :key => SHIRASETE_API_KEY
      }.to_json
    end
    return true if response.status == 200
  end

  def skip
    response = @@put_conn.put do |req|
      req.url "/issues/#{@id}.json"
      req.headers['Content-Type'] = 'application/json'
      req.body = { 
        :issue => {
          :status_id => 6
        },
        :key => SHIRASETE_API_KEY
      }.to_json
    end
    return true if response.status == 200
  end

  def set_resolved
    response = @@put_conn.put do |req|
      req.url "/issues/#{@id}.json"
      req.headers['Content-Type'] = 'application/json'
      req.body = { 
        :issue => {
          :status_id => 3
        },
        :key => SHIRASETE_API_KEY
      }.to_json
    end
    return true if response.status == 200
  end
end

use Rack::Auth::Basic do |username, password|
  username == ENV['USERNAME'] && password == ENV['PASSWORD']
end

enable :sessions

get '/' do
  @users = User.all
  haml :index
end

get '/groups/:id/tasks' do
  state = params[:state]
  @user = User.find(params[:id])
  @tasks = Task.all(@user, state)
  case state
  when 'published'
    haml :'groups/published-tasks'
  when 'skipped'
    haml :'groups/skipped-tasks'
  else
    haml :'groups/tasks'
  end
end

post '/tasks/:id/skip' do
  task = Task.find(params[:id])
  task.skip
  redirect to(params[:redirect])
end

post '/tasks/:id/unskip' do
  task = Task.find(params[:id])
  task.unskip
  redirect to(params[:redirect])
end

post '/tasks/:id/push' do
  task = Task.find(params[:id])
  push(task)
  redirect to(params[:redirect])
end

post '/tasks/:id/publish' do
  published_tasks = Task.all(User.find(params[:user_id]), 'published')
  if published_tasks.count > 0
    last_task = published_tasks.first
    last_task.set_resolved
  end

  task = Task.find(params[:id])
  task.publish

  data = {:alert => "#{task.identifier} #{task.subject}", :sound => ''}
  channel = "channel_#{task.assigned_to_id}"
  p channel
  push = Parse::Push.new(data, channel)
  push.save

  redirect to(params[:redirect])
end

def push(task)
  data = {:alert => "#{task.identifier} #{task.subject}", :sound => ''}
  channel = "channel_#{task.assigned_to_id}"
  push = Parse::Push.new(data, channel)
  push.save
end

