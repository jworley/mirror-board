require 'google/api_client'
require 'sinatra/base'
require 'rack-flash'

require './models'

class MirrorBoard < Sinatra::Base
  def self.google_config
    @@google_config ||= (
	  config_path = File.join(settings.root, 'config', 'google.yml')
	  YAML.load_file(config_path)[environment.to_s]
	)
  end
  SCOPES = %w{ userinfo.email userinfo.profile glass.timeline }
  enable :sessions
  use Rack::Flash

  use OmniAuth::Builder do
    provider(:google_oauth2,
	  MirrorBoard.google_config['client_id'],
	  MirrorBoard.google_config['client_secret'],
	  scope: SCOPES.join(','),
	  approval_prompt: 'force',
	  access_type: 'offline')
  end

  def api_client; settings.api_client; end
  def mirror_api; settings.mirror_api; end

  def user_credentials
    @authorization ||= (
      auth = api_client.authorization.dup
      auth.redirect_uri = to('/auth/google_oauth2/callback')
      user = User.find(session['uid'])
      auth.update_token!({
        token: user.token,
        refresh_token: user.refresh_token,
        expires_at: user.expires_at,
        expires: user.expires
      })
    )
  end
  
  def bootstrap_user
    auth = user_credentials
    text = 'Welcome to Mirror-Board'
    welcome = mirror_api.timeline.insert.request_schema.new({ 'text' => text })
    api_client.execute(
      api_method: mirror_api.timeline.insert,
      body_object: welcome,
      authorization: auth
    )
    contact = mirror_api.contact.insert.request_schema.new({
      'id' => 'mirror-board-contact',
      'displayName' => 'MirrorBoard',
      'imageUrls' => [ to('contact.png') ]
    })
    api_client.execute(
      api_method: mirror_api.contact.insert,
      body_object: contact,
      authorization: auth
    )
    sub = mirror_api.subscription.insert.request_schema.new({
      'collection' => 'timeline',
      'userToken' => session['uid'],
      'callbackUrl' => to('/google/notify')
    })
    api_client.execute(
      api_method: mirror_api.subscription.insert,
      body_object: sub,
      authorization: auth
    )
  end
  
  configure do
    client = Google::APIClient.new
    client.authorization.client_id = MirrorBoard.google_config['client_id']
    client.authorization.client_secret = MirrorBoard.google_config['client_secret']
    client.authorization.scope = SCOPES

    mirror_api = client.discovered_api('mirror', 'v1')

    set :api_client, client
    set :mirror_api, mirror_api
  end

  post '/google/notify' do
    notification = JSON.parse(request.body)
    if notification['userActions'].first['type'] == 'SHARE'
      session['uid'] = notification['userToken']
      user = User.find(session['uid'])
      auth = user_credentials
      result = api_client.execute(
        api_method: mirror_api.timeline.get,
        parameters: { 'id' => notification['itemId'] }
      )
      if result.success?
        timeline_item = result.data
        timeline_item.attachments.each do |attachment|
          session['uid'] = notification['userToken']
          post = user.posts.new(
            timeline_id: timeline_item.id,
            attachment_id: attachment.id,
            content_type: attachment.contentType,
            created: timeline_item.created
          )
          ext = MIME::Types[post.content_type].first.extensions.first
          filename = "#{post.attachment_id}.#{ext}"
          post.content_path = filename
          attached_file = api_client.execute(uri: attachment.content_url)
          File.open(File.join(settings.root, 'public', 'usercontent', filename), 'w') do |f|
            f.write(attached_file.body)
          end
          post.save
        end
      end
    end
  end

  %w{ get post }.each do |verb|
    send(verb, '/auth/:provider/callback') do
      begin
        user = User.get!(request.env['omniauth.auth']['uid'])
        user.update(request.env['omniauth.auth']['credentials'])
        session['uid'] = request.env['omniauth.auth']['uid']
        redirect to('/')
      rescue DataMapper::ObjectNotFoundError
        session['omniauth.auth'] = request.env['omniauth.auth']
        redirect to('/new_user')
      end
    end
  end

  get '/auth/failure' do
    content_type 'text/plain'
    'Something went wrong'
  end

  get '/new_user' do
    haml :new_user
  end

  post '/new_user' do
    redirect to('/') unless session.key?('omniauth.auth')
    user = User.new(session['omniauth.auth']['credentials'])
    user.uid = session['omniauth.auth']['uid']
    user.username = params['username']
    session.delete('omniauth.auth')
    session['uid'] = user.uid
    if user.save
      flash[:info] = haml :welcome_flash, layout: nil
      redirect to('/')
    else
      flash.now[:error] = haml :error_flash, layout: nil, locals: { errors: user.errors }
      haml :new_user
    end
  end

  get '/user/:username' do |username|
    @user = User.first(username: username)
    @posts = @user.posts(order: [ :created.desc ])
    haml :user
  end

  get '/' do
    @user_content = Post.all(order: [ :created.desc ], limit: 20)
    haml :index
  end
end
