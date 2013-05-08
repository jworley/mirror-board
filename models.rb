require 'data_mapper'

DataMapper.setup(:default, "sqlite3://#{Dir.pwd}/development.db")

class User
  include DataMapper::Resource
  property :uid,            String, key: true
  property :username,       String, required: true, unique: true
  property :token,          String, length: 256
  property :refresh_token,  String, length: 256
  property :expires_at,     Integer
  property :expires,        Boolean

  has n, :posts
end

class Post
  include DataMapper::Resource
  property :id,             Serial
  property :attachment_id,  String, length: 256
  property :timeline_id,    String, length: 256
  property :content_type,   String
  property :content_path,   String
  property :created,        DateTime

  belongs_to :user
end

DataMapper.finalize.auto_upgrade!
