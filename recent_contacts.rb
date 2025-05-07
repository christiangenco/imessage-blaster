#!/usr/bin/env ruby

require 'shellwords'

def get_recent_contacts(count = 5)
  # AppleScript to get recent contacts
  script = <<~EOF
    tell application "Messages"
      set recentContacts to {}

      -- Get the #{count} most recent chats
      repeat with i from 1 to #{count}
        try
          set theChat to chat i
          set chatParticipants to participants of theChat
          set theParticipant to first item of chatParticipants

          -- Get contact details
          set contactName to full name of theParticipant
          set contactHandle to handle of theParticipant

          -- Add to our list
          set end of recentContacts to {contactName, contactHandle}
        on error
          exit repeat
        end try
      end repeat

      return recentContacts
    end tell
  EOF

  # Execute AppleScript and capture output
  result = `osascript -e #{Shellwords.escape(script)}`

  # Parse the AppleScript result
  contacts = []
  result.split(',').each_slice(2) do |name, handle|
    contacts << {
      name: name.strip,
      handle: handle.strip
    }
  end

  contacts
end

contacts = get_recent_contacts
p contacts

# Example of sending a message to the first contact
if false && contacts.any?
  first_contact = contacts.first
  puts "\nExample of sending a message to the first contact:"
  puts "Sending test message to: #{first_contact[:name]} (#{first_contact[:handle]})"

  message_script = <<~EOF
    tell application "Messages"
      set targetBuddy to buddy "#{first_contact[:handle]}" of service "iMessage"
      send "This is a test message from the Ruby script!" to targetBuddy
    end tell
  EOF

  system("osascript -e #{Shellwords.escape(message_script)}")
  puts 'Message sent!'
end
