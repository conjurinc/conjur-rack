require "conjur/rack/user"
require 'set'
require 'rack/request'

module Conjur
  module Rack

    class << self
      def conjur_rack
        Thread.current[:conjur_rack] ||= {}
      end

      def identity?
        !conjur_rack[:identity].nil?
      end
      
      def user
        User.new(identity[0], identity[1], 
          :privilege => privilege, 
          :remote_ip => remote_ip, 
          :audit_roles => audit_roles, 
          :audit_resources => audit_resources
          )
      end
      
      def identity
        conjur_rack[:identity] or raise "No Conjur identity for current request"
      end

      # class attributes
      [:privilege, :remote_ip, :audit_roles, :audit_resources].each do |a|
        define_method(a) do
          conjur_rack[a]
        end
      end
    end

  
    class Authenticator
      class AuthorizationError < SecurityError
      end
      class SignatureError < SecurityError
      end
      
      attr_reader :app, :options
      
      # +options+:
      # :except :: a list of request path patterns for which to skip authentication.
      # :optional :: request path patterns for which authentication is optional.
      def initialize app, options = {}
        @app = app
        @options = options
      end

      # threadsafe accessors, values are established explicitly below
      def env; Thread.current[:rack_env] ; end

      # instance attributes
      [:token, :account, :privilege, :remote_ip, :audit_roles, :audit_resources].each do |a|
        define_method(a) do
          conjur_rack[a]
        end
      end
 
      def call rackenv
        # never store request-specific variables as application attributes 
        Thread.current[:rack_env] = rackenv
        if authenticate?
          begin
            identity = verify_authorization_and_get_identity # [token, account]
            
            if identity
              conjur_rack[:token] = identity[0]
              conjur_rack[:account] = identity[1]
              conjur_rack[:identity] = identity
              conjur_rack[:privilege] = http_privilege
              conjur_rack[:remote_ip] = http_remote_ip
              conjur_rack[:audit_roles] = http_audit_roles
              conjur_rack[:audit_resources] = http_audit_resources
            end

          rescue SecurityError, RestClient::Exception
            return error 401, $!.message
          end
        end
        begin
          @app.call rackenv
        ensure
          Thread.current[:rack_env] = nil
          Thread.current[:conjur_rack] = {}
        end
      end
      
      protected
      
      def conjur_rack
        Conjur::Rack.conjur_rack
      end

      def validate_token_and_get_account token
        failure = SignatureError.new("Unauthorized: Invalid token")
        raise failure unless (signer = Slosilo.token_signer token)
        if signer == 'own'
          ENV['CONJUR_ACCOUNT'] or raise failure
        else
          raise failure unless signer =~ /\Aauthn:(.+)\z/
          $1
        end
      end
      
      def error status, message
        [status, { 'Content-Type' => 'text/plain', 'Content-Length' => message.length.to_s }, [message] ]
      end
      
      def verify_authorization_and_get_identity
        if http_authorization.to_s[/^Token token="(.*)"/]
          token = JSON.parse(Base64.decode64($1))
          account = validate_token_and_get_account(token)
          return [token, account]
        else
          path = http_path
          if optional_paths.find{|p| p.match(path)}.nil?
            raise AuthorizationError.new("Authorization missing")
          else
            nil
          end
        end
      end
      
      def authenticate?
        path = http_path
        if options[:except]
          options[:except].find{|p| p.match(path)}.nil?
        else
          true
        end
      end
      
      def optional_paths
        options[:optional] || []
      end

      def http_authorization
        env['HTTP_AUTHORIZATION']
      end

      def http_privilege
        env['HTTP_X_CONJUR_PRIVILEGE']
      end

      def http_remote_ip
        require 'rack/request'
        ::Rack::Request.new(env).ip
      end

      def http_audit_roles
        env['HTTP_CONJUR_AUDIT_ROLES']
      end

      def http_audit_resources
        env['HTTP_CONJUR_AUDIT_RESOURCES']
      end

      def http_path
        [ env['SCRIPT_NAME'], env['PATH_INFO'] ].join
      end

    end
  end
end
