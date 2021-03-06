
# gem
require 'yajl'
require 'rest_client'

# stdlib
require 'digest/md5'
require 'openssl'

require 'cgi'

# optional gem
begin
  require 'rack'
rescue LoadError; end


# the data structure used in RestGraph
RestGraphStruct = Struct.new(:auto_decode,
                             :graph_server, :old_server,
                             :accept, :lang,
                             :app_id, :secret,
                             :data, :cache,
                             :error_handler,
                             :log_handler) unless defined?(RestGraphStruct)

class RestGraph < RestGraphStruct
  class Error < RuntimeError; end
  class Event < Struct.new(:duration, :url); end
  class Event::Requested < Event; end
  class Event::CacheHit  < Event; end

  Attributes = RestGraphStruct.members.map(&:to_sym)

  # honor default attributes
  Attributes.each{ |name|
    module_eval <<-RUBY
      def #{name}
        (r = super).nil? ? (self.#{name} = self.class.default_#{name}) : r
      end
    RUBY
  }

  # setup defaults
  module DefaultAttributes
    extend self
    def default_auto_decode ; true                         ; end
    def default_graph_server; 'https://graph.facebook.com/'; end
    def default_old_server  ; 'https://api.facebook.com/'  ; end
    def default_accept      ; 'text/javascript'            ; end
    def default_lang        ; 'en-us'                      ; end
    def default_app_id      ; nil                          ; end
    def default_secret      ; nil                          ; end
    def default_data        ; {}                           ; end
    def default_cache       ; nil                          ; end
    def default_error_handler
      lambda{ |error| raise ::RestGraph::Error.new(error) }
    end
    def default_log_handler
      lambda{ |event| }
    end
  end
  extend DefaultAttributes

  def initialize o={}
    (Attributes + [:access_token]).each{ |name|
      send("#{name}=", o[name]) if o.key?(name)
    }
  end

  def access_token
    data['access_token'] || data['oauth_token']
  end

  def access_token= token
    data['access_token'] = token
  end

  def authorized?
    !!access_token
  end

  def url path, query={}, server=graph_server
    "#{server}#{path}#{build_query_string(query)}"
  end

  def get    path, query={}, opts={}
    request(:get   , url(path, query, graph_server), opts)
  end

  def delete path, query={}, opts={}
    request(:delete, url(path, query, graph_server), opts)
  end

  def post   path, payload, query={}, opts={}
    request(:post  , url(path, query, graph_server), opts, payload)
  end

  def put    path, payload, query={}, opts={}
    request(:put   , url(path, query, graph_server), opts, payload)
  end

  # cookies, app_id, secrect related below

  def parse_rack_env! env
    env['HTTP_COOKIE'].to_s =~ /fbs_#{app_id}=([^\;]+)/
    self.data = parse_fbs!($1)
  end

  def parse_cookies! cookies
    self.data = parse_fbs!(cookies["fbs_#{app_id}"])
  end

  def parse_fbs! fbs
    self.data = check_sig_and_return_data(
      # take out facebook sometimes there but sometimes not quotes in cookies
      Rack::Utils.parse_query(fbs.to_s.gsub('"', '')))
  end

  def parse_json! json
    self.data = json &&
      check_sig_and_return_data(Yajl::Parser.parse(json))
  rescue Yajl::ParseError
  end

  def fbs
    "#{fbs_without_sig(data).join('&')}&sig=#{calculate_sig(data)}"
  end

  # facebook's new signed_request...

  def parse_signed_request! request
    sig_encoded, json_encoded = request.split('.')
    sig,  json = [sig_encoded, json_encoded].map{ |str|
      "#{str.tr('-_', '+/')}==".unpack('m').first
    }
    self.data = Yajl::Parser.parse(json) if
      secret && OpenSSL::HMAC.digest('sha256', secret, json_encoded) == sig
  rescue Yajl::ParseError
  end

  # oauth related

  def authorize_url opts={}
    query = {:client_id => app_id, :access_token => nil}.merge(opts)
    "#{graph_server}oauth/authorize#{build_query_string(query)}"
  end

  def authorize! opts={}
    query = {:client_id => app_id, :client_secret => secret}.merge(opts)
    self.data = Rack::Utils.parse_query(
                  request(:get, url('oauth/access_token', query),
                          :suppress_decode => true))
  end

  # old rest facebook api, i will definitely love to remove them someday

  def old_rest path, query={}, opts={}
    request(
      :get,
      url("method/#{path}", {:format => 'json'}.merge(query), old_server),
      opts)
  end

  def exchange_sessions opts={}
    query = {:client_id => app_id, :client_secret => secret,
             :type => 'client_cred'}.merge(opts)
    request(:post, url('oauth/exchange_sessions', query))
  end

  def fql code, query={}, opts={}
    old_rest('fql.query', {:query => code}.merge(query), opts)
  end

  def fql_multi codes, query={}, opts={}
    c = Yajl::Encoder.encode(codes)
    old_rest('fql.multiquery', {:queries => c}.merge(query), opts)
  end

  private
  def request meth, uri, opts={}, payload=nil
    start_time = Time.now
    post_request(cache_get(uri) || fetch(meth, uri, payload),
                 opts[:suppress_decode])
  rescue RestClient::Exception => e
    post_request(e.http_body, opts[:suppress_decode])
  ensure
    log_handler.call(Event::Requested.new(Time.now - start_time, uri))
  end

  def build_query_string query={}
    qq = access_token ? {:access_token => access_token}.merge(query) : query
    q  = qq.select{ |k, v| v }
    return '' if q.empty?
    return '?' + q.map{ |(k, v)| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
  end

  def build_headers
    headers = {}
    headers['Accept']          = accept if accept
    headers['Accept-Language'] = lang   if lang
    headers
  end

  def post_request result, suppress_decode=nil
    if auto_decode && !suppress_decode
      check_error(Yajl::Parser::parse(result))
    else
      result
    end
  end

  def check_sig_and_return_data cookies
    cookies if secret && calculate_sig(cookies) == cookies['sig']
  end

  def check_error hash
    if error_handler && hash.kind_of?(Hash) &&
       (hash['error'] ||    # from graph api
        hash['error_code']) # from fql
      error_handler.call(hash)
    else
      hash
    end
  end

  def calculate_sig cookies
    Digest::MD5.hexdigest(fbs_without_sig(cookies).join + secret)
  end

  def fbs_without_sig cookies
    cookies.reject{ |(k, v)| k == 'sig' }.sort.map{ |a| a.join('=') }
  end

  def cache_key uri
    Digest::MD5.hexdigest(uri)
  end

  def cache_get uri
    return unless cache
    start_time = Time.now
    cache[cache_key(uri)].tap{ |result|
      log_handler.call(Event::CacheHit.new(Time.now - start_time, uri)) if
        result
    }
  end

  def fetch meth, uri, payload
    RestClient::Request.execute(:method => meth, :url => uri,
                                :headers => build_headers,
                                :payload => payload).
      tap{ |result|
        cache[cache_key(uri)] = result if cache
      }
  end
end
