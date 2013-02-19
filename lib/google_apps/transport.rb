require 'cgi'
require 'openssl'
require 'rexml/document'

module GoogleApps
  class Transport
    attr_reader :domain, :token
    attr_reader :user, :group, :nickname, :export, :pubkey, :requester, :migration

    BOUNDARY = "=AaB03xDFHT8xgg"
    PAGE_SIZE = {
      user: 100,
      group: 200
    }
    FEEDS_ROOT = 'https://apps-apis.google.com/a/feeds'

    def initialize(options)
      @domain = options[:domain]
      @token = options[:token]
      @refresh_token = options[:refresh_token]
      @token_changed_callback = options[:token_changed_callback]

      @user       = "#{FEEDS_ROOT}/#{@domain}/user/2.0"
      @pubkey     = "#{FEEDS_ROOT}/compliance/audit/publickey/#{@domain}"
      @migration  = "#{FEEDS_ROOT}/migration/2.0/#{@domain}"
      @group      = "#{FEEDS_ROOT}/group/2.0/#{@domain}"
      @nickname   = "#{FEEDS_ROOT}/#{@domain}/nickname/2.0"

      audit_root  = "#{FEEDS_ROOT}/compliance/audit/mail"
      @export     = "#{audit_root}/export/#{@domain}"
      @monitor    = "#{audit_root}/monitor/#{@domain}"

      @requester = AppsRequest
      @doc_handler = DocumentHandler.new(format: :atom)
    end

    # request_export performs the GoogleApps API call to
    # generate a mailbox export.  It takes the username
    # and an GoogleApps::Atom::Export instance as
    # arguments
    #
    # request_export 'username', document
    #
    # request_export returns the request ID on success or
    # the HTTP response object on failure.
    def request_export(username, document)
      response = add(export + "/#{username}", document)
      process_response(response)
      export = create_doc(response.body, :export_response)

      export.find('//apps:property').inject(nil) do |request_id, node|
        node.attributes['name'] == 'requestId' ? node.attributes['value'].to_i : request_id
      end
    end


    # export_status checks the status of a mailbox export
    # request.  It takes the username and the request_id
    # as arguments
    #
    # export_status 'username', 847576
    #
    # export_status will return the body of the HTTP response
    # from Google
    def export_status(username, req_id)
      response = get(export + "/#{username}", req_id)
      process_response(response)
      create_doc(response.body, :export_status)
    end

    def create_doc(response_body, type = nil)
      @doc_handler.create_doc(response_body, type)
    end

    # export_ready? checks the export_status response for the
    # presence of an apps:property element with a fileUrl name
    # attribute.
    #
    # export_ready?(export_status('username', 847576))
    #
    # export_ready? returns true if there is a fileUrl present
    # in the response and false if there is no fileUrl present
    # in the response.
    def export_ready?(export_status_doc)
      export_file_urls(export_status_doc).any?
    end

    # fetch_export downloads the mailbox export from Google.
    # It takes a username, request id and a filename as
    # arguments.  If the export consists of more than one file
    # the file name will have numbers appended to indicate the
    # piece of the export.
    #
    # fetch_export 'lholcomb2', 838382, 'lholcomb2'
    #
    # fetch_export reutrns nil in the event that the export is
    # not yet ready.
    def fetch_export(username, req_id, filename)
      export_status_doc = export_status(username, req_id)
      if export_ready?(export_status_doc)
        download_export(export_status_doc, filename).each_with_index { |url, index| url.gsub!(/.*/, "#{filename}#{index}")}
      else
        nil
      end
    end


    # download makes a get request of the provided url
    # and writes the body to the provided filename.
    #
    # download 'url', 'save_file'
    def download(url, filename)
      request = requester.new :get, URI(url), headers(:other)

      File.open(filename, "w") do |file|
        file.puts request.send_request.body
      end
    end


    # get is a generic target for method_missing.  It is
    # intended to handle the general case of retrieving a
    # record from the Google Apps Domain.  It takes an API
    # endpoint and an id as arguments.
    #
    # get 'endpoint', 'username'
    #
    # get returns the HTTP response received from Google.
    def get(endpoint, id = nil)
      id ? uri = URI(endpoint + build_id(id)) : uri = URI(endpoint)
      request = requester.new :get, uri, headers(:other)

      request.send_request
    end


    # get_users retrieves as many users as specified from the
    # domain.  If no starting point is given it will grab all the
    # users in the domain.  If a starting point is specified all
    # users from that point on (alphabetically) will be returned.
    #
    # get_users start: 'lholcomb2'
    #
    # get_users returns the final response from google.
    def get_users(options = {})
      limit = options[:limit] || 1000000
      response = get(user + "?startUsername=#{options[:start]}")
      process_response(response)

      pages = fetch_pages(response, limit, :feed)

      return_all(pages)
    end


    # get_groups retrieves all the groups from the domain
    #
    # get_groups
    #
    # get_groups returns the final response from Google.
    def get_groups(options = {})
      limit = options[:limit] || 1000000
      response = get(group + "#{options[:extra]}" + "?startGroup=#{options[:start]}")
      process_response(response, :feed)
      pages = fetch_pages(response, limit, :feed)

      return_all(pages)
    end

    # Retrieves the members of the requested group.
    #
    # @param [String] group_id the Group ID in the Google Apps Environment
    #
    # @visibility public
    # @return
    def get_members_of(group_id, options = {})
      options[:extra] = "/#{group_id}/member"
      get_groups options
    end


    # TODO:  Refactor add tos.


    # add_member_to adds a member to a group in the domain.
    # It takes a group_id and a GoogleApps::Atom::GroupMember
    # document as arguments.
    #
    # add_member_to 'test', document
    #
    # add_member_to returns the response received from Google.
    def add_member_to(group_id, document)
      response = add(group + "/#{group_id}/member", document)
      process_response(response)
      create_doc(response.body)
    end


    #
    # @param [String] group_id The ID for the group being modified
    # @param [GoogleApps::Atom::GroupOwner] document The XML document with the owner address
    #
    # @visibility public
    # @return
    def add_owner_to(group_id, document)
      add(group + "/#{group_id}/owner", nil, document)
    end

    # TODO: Refactor delete froms.

    # delete_member_from removes a member from a group in the
    # domain.  It takes a group_id and member_id as arguments.
    #
    # delete_member_from 'test_group', 'member@cnm.edu'
    #
    # delete_member_from returns the respnse received from Google.
    def delete_member_from(group_id, member_id)
      delete(group + "/#{group_id}/member", member_id)
    end

    # @param [String] group_id Email address of group
    # @param [String] owner_id Email address of owner to remove
    #
    # @visibility public
    # @return
    def delete_owner_from(group_id, owner_id)
      delete(group + "/#{group_id}/owner", owner_id)
    end


    # get_nicknames_for retrieves all the nicknames associated
    # with the requested user.  It takes the username as a string.
    #
    # get_nickname_for 'lholcomb2'
    #
    # get_nickname_for returns the HTTP response from Google
    def get_nicknames_for(login)
      get_nickname "?username=#{login}"
    end


    # add is a generic target for method_missing.  It is
    # intended to handle the general case of adding
    # to the GoogleApps Domain.  It takes an API endpoint
    # and a GoogleApps::Atom document as arguments.
    #
    # add 'endpoint', document
    #
    # add returns the HTTP response received from Google.
    def add(endpoint, document, header_type = nil)
      header_type = :others unless header_type
      uri = URI(endpoint)
      request = requester.new :post, uri, headers(header_type)
      request.add_body document.to_s

      request.send_request
    end

    # update is a generic target for method_missing.  It is
    # intended to handle the general case of updating an
    # item that already exists in your GoogleApps Domain.
    # It takes an API endpoint and a GoogleApps::Atom document
    # as arguments.
    #
    # update 'endpoint', target, document
    #
    # update returns the HTTP response received from Google
    def update(endpoint, target, document)
      uri = URI(endpoint + "/#{target}")
      request = requester.new :put, uri, headers(:other)
      request.add_body document.to_s

      request.send_request
    end

    # delete is a generic target for method_missing.  It is
    # intended to handle the general case of deleting an
    # item from your GoogleApps Domain.  delete takes an
    # API endpoint and an item identifier as argumets.
    #
    # delete 'endpoint', 'id'
    #
    # delete returns the HTTP response received from Google.
    def delete(endpoint, id)
      uri = URI(endpoint + "/#{id}")
      request = requester.new :delete, uri, headers(:other)

      request.send_request
    end

    # migration performs mail migration from a local
    # mail environment to GoogleApps.  migrate takes a
    # username a GoogleApps::Atom::Properties dcoument
    # and the message as plain text (String) as arguments.
    #
    # migrate 'user', properties, message
    #
    # migrate returns the HTTP response received from Google.
    def migrate(username, properties, message)
      request = requester.new(:post, URI(migration + "/#{username}/mail"), headers(:migration))
      request.add_body multi_part(properties.to_s, message)

      request.send_request
    end

    def method_missing(name, *args)
      super unless name.match /([a-z]*)_([a-z]*)/

      case $1
      when "new", "add"
        response = self.send(:add, send($2), *args)
        process_response(response)
        create_doc(response.body, $2)
      when "delete"
        response = self.send(:delete, send($2), *args)
        process_response(response)
        create_doc(response.body, $2)
      when "update"
        response = self.send(:update, send($2), *args)
        process_response(response)
        create_doc(response.body, $2)
      when "get"
        response = self.send(:get, send($2), *args)
        process_response(response)
        create_doc(response.body, $2)
      else
        super
      end
    end

    private

    # build_id checks the id string.  If it is formatted
    # as a query string it is returned as is.  If not
    # a / is prepended to the id string.
    def build_id(id)
      id =~ /^\?/ ? id : "/#{id}"
    end

    # export_file_urls searches an export status doc for any apps:property elements with a
    # fileUrl name attribute and returns an array of the values.
    def export_file_urls(export_status_doc)
      export_status_doc.find("//apps:property[contains(@name, 'fileUrl')]").collect do |prop|
        prop.attributes['value']
      end
    end

    def download_export(export, filename)
      export_file_urls(export).each_with_index do |url, index|
        download(url, filename + "#{index}")
      end
    end


    # process_response takes the HTTPResponse and either returns a
    # document of the specified type or in the event of an error it
    # returns the HTTPResponse.
    def process_response(response)
      raise("Error: #{response.code}, #{response.message}") unless success_response?(response)
    end

    def success_response?(response)
      response.kind_of?(Net::HTTPSuccess)
    end

    # Takes all the items in each feed and puts them into one array.
    #
    # @visibility private
    # @return Array of Documents
    def return_all(pages)
      pages.inject([]) do |results, feed|
        results | feed.items
      end
    end

    # get_next_page retrieves the next page in the response.
    def get_next_page(next_page_url, type)
      response = get(next_page_url)
      process_response(response)
      GoogleApps::Atom.feed(response.body)
    end


    # fetch_feed retrieves the remaining pages in the request.
    # It takes a page and a limit as arguments.
    def fetch_pages(response, limit, type)
      pages = [GoogleApps::Atom.feed(response.body)]

      while (pages.last.next_page) and (pages.count * PAGE_SIZE[:user] < limit)
        pages << get_next_page(pages.last.next_page, type)
      end
      pages
    end

    def singularize(type)
      type.to_s.gsub(/s$/, '')
    end

    def headers(category)
      case category
      when :auth
        [['content-type', 'application/x-www-form-urlencoded']]
      when :migration
        [['content-type', "multipart/related; boundary=\"#{BOUNDARY}\""], ['Authorization', "OAuth #{@token}"]]
      else
        [['content-type', 'application/atom+xml'], ['Authorization', "OAuth #{@token}"]]
      end
    end

    def multi_part(properties, message)
      post_body = []
      post_body << "--#{BOUNDARY}\n"
      post_body << "Content-Type: application/atom+xml\n\n"
      post_body << properties.to_s
      post_body << "\n--#{BOUNDARY}\n"
      post_body << "Content-Type: message/rfc822\n\n"
      post_body << message.to_s
      post_body << "\n--#{BOUNDARY}--}"

      post_body.join
    end
  end
end