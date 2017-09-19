require 'spec_helper'

require 'conjur/rack/authenticator'

describe Conjur::Rack::Authenticator do
  describe "#call" do
    include_context "with authenticator"
    context "to an unprotected path" do
      let(:except) { [ /^\/foo/ ] }
      let(:env) { { 'SCRIPT_NAME' => '', 'PATH_INFO' => '/foo/bar' } }
      before {
        options[:except] = except
        expect(app).to receive(:call).with(env).and_return app
      }
      context "without authorization" do
        it "proceeds" do
          expect(call).to eq(app)
          expect(Conjur::Rack.identity?).to be(false)
        end
      end
      context "with authorization" do
        include_context "with authorization"
        it "ignores the authorization" do
          expect(call).to eq(app)
          expect(Conjur::Rack.identity?).to be(false)
        end
      end
    end

    context "to a protected path" do
      let(:env) { { 'SCRIPT_NAME' => '/pathname' } }
      context "without authorization" do
        it "returns a 401 error" do
          expect(call).to return_http 401, "Authorization missing"
        end
      end
      context "with Conjur authorization" do
        include_context "with authorization"

        context "with CIDR restriction" do
          let(:claims) { { 'sub' => 'test-user', 'cidr' => %w(192.168.2.0/24 2001:db8::/32) } }
          let(:token) { Slosilo::JWT.new(claims) }
          before do
            allow(subject).to receive_messages \
                parsed_token: token,
                http_remote_ip: remote_ip
          end

          %w(10.0.0.2 fdda:5cc1:23:4::1f).each do |addr|
            context "with address #{addr} out of range" do
              let(:remote_ip) { addr }
              it "returns 403" do
                expect(call).to return_http 403, "IP address rejected"
              end
            end
          end

          %w(192.168.2.3 2001:db8::22).each do |addr|
            context "with address #{addr} in range" do
              let(:remote_ip) { addr }
              it "passes the request" do
                expect(call.login).to eq 'test-user'
              end
            end
          end
        end

        context "of a valid token" do
          it 'launches app' do
            expect(app).to receive(:call).with(env).and_return app
            expect(call).to eq(app)
          end
        end
        context "of an invalid token" do
          it "returns a 401 error" do
            allow(Slosilo).to receive(:token_signer).and_return(nil)
            expect(call).to return_http 401, "Unauthorized: Invalid token"
          end
        end
        context "of a token invalid for authn" do
          it "returns a 401 error" do
            allow(Slosilo).to receive(:token_signer).and_return('a-totally-different-key')
            expect(call).to return_http 401, "Unauthorized: Invalid token"
          end
        end
        context "of 'own' token" do
          it "returns ENV['CONJUR_ACCOUNT']" do
            expect(ENV).to receive(:[]).with("CONJUR_ACCOUNT").and_return("test-account")
            expect(app).to receive(:call) do |*args|
              expect(Conjur::Rack.identity?).to be(true)
              expect(Conjur::Rack.user.account).to eq('test-account')
              :done
            end
            allow(Slosilo).to receive(:token_signer).and_return('own')
            expect(call).to eq(:done)
          end
          it "requires ENV['CONJUR_ACCOUNT']" do
            expect(ENV).to receive(:[]).with("CONJUR_ACCOUNT").and_return(nil)
            allow(Slosilo).to receive(:token_signer).and_return('own')
            expect(call).to return_http 401, "Unauthorized: Invalid token"
          end
        end
      end

      context "with junk in token" do
        let(:env) { { 'HTTP_AUTHORIZATION' => 'Token token="open sesame"' } }
        it "returns 401" do
          expect(call).to return_http 401, "Malformed authorization token"
        end
      end

      context "with JSON junk in token" do
        let(:env) { { 'HTTP_AUTHORIZATION' => 'Token token="eyJmb28iOiAiYmFyIn0="' } }
        before do
          allow(Slosilo).to receive(:token_signer).and_return(nil)
        end

        it "returns 401" do
            expect(call).to return_http 401, "Unauthorized: Invalid token"
        end
      end
    end
    context "to an optional path" do
      let(:optional) { [ /^\/foo/ ] }
      let(:env) { { 'SCRIPT_NAME' => '', 'PATH_INFO' => '/foo/bar' } }
      before {
        options[:optional] = optional
      }
      context "without authorization" do
        it "proceeds" do
          expect(app).to receive(:call) do |*args|
            expect(Conjur::Rack.identity?).to be(false)
            :done
          end
          expect(call).to eq(:done)
        end
      end
      context "with authorization" do
        include_context "with authorization"
        it "processes the authorization" do
          expect(app).to receive(:call) do |*args|
            expect(Conjur::Rack.identity?).to be(true)
            :done
          end
          expect(call).to eq(:done)
        end
      end
    end

    RSpec::Matchers.define :return_http do |status, message|
      match do |actual|
        status, headers, body = actual
        expect(status).to eq status
        expect(headers).to eq "Content-Type" => "text/plain", "Content-Length" => message.length.to_s
        expect(body.join).to eq message
      end
    end
  end
end
