#!/usr/bin/env ruby
# frozen_string_literal: true

require 'shellwords'
require 'open3'
require 'json'

CONTACTS_FILE = 'contacts.txt'
BLOCKED_CONTACTS_FILE = 'blocked_contacts.txt'
PROCESSED_IDS_FILE = 'processed_message_ids.txt'
MESSAGES_FILE = 'messages.json'
REFRESH_INTERVAL_SECONDS = 30

def messages
  @last_fetch_time ||= Time.at(0)
  @cached_messages ||= {}

  # Refresh if more than 30 seconds have passed since last fetch
  if Time.now - @last_fetch_time > REFRESH_INTERVAL_SECONDS / 2
    # Calculate date 14 days ago
    start_date = (Time.now - 14 * 24 * 60 * 60).strftime('%Y-%m-%d')
    puts "Fetching messages from #{start_date}..."
    system("./imessagedump -o messages.json --start-date #{start_date} --only-from-me")
    @last_fetch_time = Time.now

    # Load the fresh data
    @cached_messages = if File.exist?(MESSAGES_FILE)
                         begin
                           JSON.parse(File.read(MESSAGES_FILE), symbolize_names: false).map do |msg|
                             msg.merge('id' => msg['id'].to_s)
                           end
                         rescue JSON::ParserError => e
                           warn "Error parsing messages file: #{e.message}"
                           []
                         end
                       end
  end

  @cached_messages
end

def blocked_contacts
  File.exist?(BLOCKED_CONTACTS_FILE) ? File.readlines(BLOCKED_CONTACTS_FILE, chomp: true) : []
end

def contacts
  all_contacts = File.exist?(CONTACTS_FILE) ? File.readlines(CONTACTS_FILE, chomp: true) : []
  all_contacts - blocked_contacts
end

# Send an iMessage via the macOS Messages app.
def send_sms(number, message)
  applescript = <<~'APPLESCRIPT'
    on run {targetPhone, sendText}
      tell application "Messages"
        activate
        -- pick the first iMessage account (works for most setups)
        set targetService to first service whose service type = iMessage

        -- try to reuse an existing chat, otherwise create one
        if (exists (buddy targetPhone of targetService)) then
          set targetBuddy to buddy targetPhone of targetService
          send sendText to targetBuddy
        else
          set newChat to make new text chat with properties {service:targetService, participants:{targetPhone}}
          send sendText to newChat
        end if
      end tell
    end run
  APPLESCRIPT

  # Pass the script on STDIN and the 2 arguments on ARGV to osascript
  Open3.popen3('osascript', '-', number, message) do |stdin, stdout, stderr, wait_thr|
    stdin.write(applescript)
    stdin.close
    warn stderr.read unless (err = stderr.read).empty?
    wait_thr.value.success? or raise 'osascript failed'
  end
end

def setup_contacts_file
  return if File.exist?(CONTACTS_FILE)

  puts 'contacts.txt not found. Searching for initial contacts...'
  meditation_messages = messages.select { |msg| msg['text']&.downcase&.include?('meditation') }
  # avoid infinite loops by making sure we don't add our own number to the contacts list
  meditation_messages = meditation_messages.reject { |msg| msg['from'] == msg['to'] }
  contacts = meditation_messages.map { |msg| msg['to'] }.uniq

  File.write(CONTACTS_FILE, contacts.join("\n"))
  puts "Created contacts.txt with #{contacts.length} contacts."
end

loop do
  puts 'Checking for new messages...'
  processed_ids = File.exist?(PROCESSED_IDS_FILE) ? File.readlines(PROCESSED_IDS_FILE, chomp: true) : []

  messages_to_myself = messages.select { |msg| msg['from'] == msg['to'] }

  # If processed_ids is empty, write all message IDs to the file
  if processed_ids.empty? && !messages.empty?
    puts 'No processed message IDs found. Initializing with current message IDs...'
    File.open(PROCESSED_IDS_FILE, 'w') do |file|
      messages.each do |msg|
        file.puts msg['id'] if msg['id']
      end
    end
    processed_ids = messages.map { |msg| msg['id'] }.compact
    puts "Initialized processed_message_ids.txt with #{processed_ids.size} message IDs."
  end

  # Filter messages to myself that haven't been processed yet
  actionable_messages = messages_to_myself.select do |msg|
    msg['id'] && !processed_ids.include?(msg['id'])
  end

  puts "Found #{actionable_messages.length} new messages to process."

  unless actionable_messages.empty?
    # mark these messages as processed
    File.open(PROCESSED_IDS_FILE, 'a') do |file|
      actionable_messages.each do |msg|
        file.puts msg['id']
      end
    end

    messages_to_send = actionable_messages.map { |msg| msg['text'] }.filter do |text|
      text.downcase.include?('meditation') || text.downcase.include?('spotify')
    end

    unless messages_to_send.empty?
      puts "Sending #{messages_to_send.length} messages to #{contacts.length} contacts..."
      contacts.each do |contact|
        puts "Sending to #{contact}..."
        messages_to_send.each do |message|
          send_sms(contact, message)
          sleep 1
        end
      end
    end

    # is the message a phone number? let's add it to the contacts file
    actionable_messages.each do |msg|
      text = msg['text'].to_s.strip.downcase

      # Check if message is about removing/deleting a number
      next unless text =~ /(remove|delete|block)?\s*([\d\-\s()+]+)/i

      number = Regexp.last_match(2) || Regexp.last_match(1)
      number = number.strip
      number = number.gsub(/[\s\-()]/, '')
      number = "+1#{number}" unless number.start_with?('+')

      # skip this message if the number isn't long enought o be a phone number
      next unless number.length >= 10

      is_blocked = text.include?('remove') || text.include?('delete') || text.include?('block')
      output_file = is_blocked ? BLOCKED_CONTACTS_FILE : CONTACTS_FILE
      File.open(output_file, 'a') do |file|
        file.puts number
      end
      puts "Added #{number} to #{is_blocked ? 'blocked' : ''} contacts."
    end
  end

  puts "Waiting for #{REFRESH_INTERVAL_SECONDS} seconds..."
  sleep REFRESH_INTERVAL_SECONDS
end
