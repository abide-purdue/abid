class Messenger < Bot
  # The Discord server this bot manages, matched by the Server row's name.
  ABIDE_SERVER_NAME = 'Abide'.freeze

  attr_reader :bot, :map, :token

  # Messenger inherits from Bot but is *constructed by* Bot#initialize, so it
  # deliberately never calls super — which left every Messenger with @scheduler
  # nil while still inheriting Bot#bot_schedule. Bot#initialize assigns this
  # once the scheduler exists.
  attr_accessor :scheduler

  # @param bot token [String]
  def initialize(token)
    @token = token
    @map = Map.new
    # server_message_reactions (1 << 10) is required for reaction_add /
    # reaction_remove to fire at all — without it the handlers register and
    # silently never run. It is unprivileged, so no developer-portal change.
    #
    @bot = Discordrb::Commands::CommandBot.new token: @token, prefix: "!",
                                               intents: gateway_intents,
                                               ignore_bots: true
    @bot.init_cache
    register_commands
    set_button_handlers
    set_modal_handlers
    set_commands
    set_event_handlers
    at_exit do
      @bot.stop
    end
  end

  # DM any user. Returns false rather than raising when Discord refuses —
  # "cannot send messages to this user" (code 50007) is a normal outcome when
  # someone has DMs closed, not an error worth taking a job down for.
  #
  # @param user [User]
  # @param message [String]
  # @return [Boolean] whether it was delivered
  def dm_user(user, message)
    return false if user&.discord_id.blank?

    @bot.user(user.discord_id).dm(message)
    true
  rescue StandardError => e
    warn "DM to #{user.display_name} failed: #{e.class}: #{e.message}"
    false
  end

  # Replaces the old hardcoded dm_ian/dm_alan, which looked up a user by the
  # literal name 'ian' and raised NoMethodError on nil if no such row existed.
  #
  # @param message [String]
  def dm_leaders(message)
    User.leaders.find_each { |leader| dm_user(leader, message) }
  end

  # @param server id [Integer]
  # @return array of roles [Array<Discordrb::Role>]
  def get_all_roles(server)
    @bot.server(server).roles
  end

  # @param background [true, false]
  def run(background=true)
    @bot.run(background)
    true
  end

  # @param channel id [Discordrb::Channel, String, Integer]
  # @param message [String]
  # @param tts [true, false]
  # @param embeds [Hash, Discordrb::Webhooks::Embed, Array<Hash>, Array<Discordrb::Webhooks::Embed> nil]
  # @param attachments [Array<File>]
  # @param allowed_mentions [Hash, Discordrb::AllowedMentions, false, nil]
  # @param message_reference [Hash, Discordrb::AllowedMentions, false, nil]
  # @param components [View, Array<Hash>]
  # @param timeout [Float, nil]
  # @returns [Discordrb::Message]
  def send(channel, message, tts:false, embeds:nil, attachments:nil, allowed_mentions:false, message_reference:nil, components:nil, timeout:nil)
    @bot.send(channel, message, tts: tts, embeds: embeds, attachments: attachments, allowed_mentions: allowed_mentions, message_reference: message_reference, components: components, timeout: timeout)
  end

  private

  # server_messages, server_members and server_message_reactions are all
  # unprivileged. MESSAGE_CONTENT is not — and it is only requested when a
  # snipes channel is configured, because a bot that asks for a privileged
  # intent the developer portal has not granted is refused at connect: the
  # whole bot, rides included, would be down. Enabling snipes is therefore a
  # deliberate two-step (portal toggle, then `rake snipes:channel` + restart),
  # and merged code with the feature dormant behaves exactly as before.
  #
  # Snipes::Enforcer rescues its own DB access, so a fresh database with no
  # channels table yet simply means "not enabled".
  def gateway_intents
    intents = [:server_messages, :server_members, :server_message_reactions]
    if Snipes::Enforcer.enabled?
      warn 'snipes channel configured — requesting the Message Content intent (must be enabled in the developer portal)'
      intents << Snipes::Enforcer::MESSAGE_CONTENT_INTENT
    end
    intents
  end

  def register_commands
    bot.register_application_command(:event, 'event commands') do |event_cmd|
      event_cmd.subcommand(:create, 'create a new event')
    end

    # Guild-scoped so it appears instantly rather than waiting on Discord's
    # global command propagation. Falls back to a global command when the
    # server has not been seeded yet — this used to be
    # `Server.find_by(name: 'Abide').discord_id`, which killed the whole boot
    # with a NoMethodError on a fresh database.
    abide = Server.find_by(name: ABIDE_SERVER_NAME)
    warn "no '#{ABIDE_SERVER_NAME}' server row — run `rake db:seed` first" if abide.nil?

    if abide
      bot.register_application_command(:say, 'have abide bot say something', server_id: abide.discord_id) do |command|
        command.string :message, 'The message to send', required: true
        command.channel :channel, 'The destination channel', required: true
      end
      bot.register_application_command(:login, 'send a login code', server_id: abide.discord_id)
      bot.register_application_command(:'toggle-sniping', 'opt out of being sniped, or back in', server_id: abide.discord_id)
    else
      bot.register_application_command(:say, 'have abide bot say something') do |command|
        command.string :message, 'The message to send', required: true
        command.channel :channel, 'The destination channel', required: true
      end
      bot.register_application_command(:login, 'send a login code')
      bot.register_application_command(:'toggle-sniping', 'opt out of being sniped, or back in')
    end
  end

  def set_commands
    bot.command :user do |event|
      event.user.name
    end

    bot.application_command(:event).subcommand(:create) do |event|
      return event.respond(content: 'You are not allowed to do that!') unless User.find_by(discord_id: event.user.id).leader
      event_create_message event
    end

    bot.application_command(:say) do |event|
      message = event.options[:message] || event.options['message']
      channel_id = event.options[:channel] || event.options['channel']

      return event.respond('You are not able to do that!', ephemeral: true) unless user.leader
      bot.send_message(channel_id, message)
      event.respond "Message #{message} sent to channel #{channel_id}", ephemeral: true
    end

    bot.application_command(:login) do |event|
      user = User.find_by(discord_id: event.user.id)
      return event.respond('You are not able to do that!', ephemeral: true) unless user.leader
      handle_login_code(user)
      event.respond content: 'Your login code has been sent', ephemeral: true
    end

    # The same switch as the two buttons, for people who would rather type it
    # — or who cannot find the pinned message. Anyone may use it; the reply is
    # ephemeral. Default is snipable, so a first use opts out.
    bot.application_command(:'toggle-sniping') do |event|
      result = Snipes::Preference.toggle(
        discord_id: event.user.id, username: event.user.username, display_name: safe_display_name(event)
      )
      event.respond(content: Snipes::Preference.reply_for(result.opt_out), ephemeral: true)
    rescue StandardError => e
      warn "toggle-sniping failed for #{event.user&.id}: #{e.class}: #{e.message}"
      event.respond(content: 'Something went wrong saving that — try again in a moment.', ephemeral: true)
    end

    # The /debug command used to open `binding.irb` on the host for anyone with
    # the `leader` flag — which is granted automatically from the Leaders and
    # Coordinator Discord roles. That is a remote Ruby shell handed out by role
    # assignment, so it's gone. Use `bin/console` locally instead.
  end

  def set_modal_handlers
    bot.modal_submit custom_id: /create_event_modal_1_(\d+)/ do |event|
      id = event.custom_id.match(/create_event_modal_1_(\d+)/)[1].to_i
      handle_event_create_pt_one event, id
    end

    bot.modal_submit custom_id: /create_event_modal_2_(\d+)/ do |event|
      id = event.custom_id.match(/create_event_modal_2_(\d+)/)[1].to_i
      handle_event_create_pt_two event, id
    end

    bot.modal_submit custom_id: /create_event_modal_3_(\d+)/ do |event|
      id = event.custom_id.match(/create_event_modal_3_(\d+)/)[1].to_i
      handle_event_create_pt_three event, id
    end
  end

  def set_button_handlers
    bot.button custom_id: /event_create_modal_1_(\d+)/ do |event|
      return event.respond('You don\'t have permission to do this!') unless User.find_by(discord_id: event.user.id).leader
      id = event.custom_id.match(/event_create_modal_1_(\d+)/)[1].to_i
      event_create_pt_one event, id
    end

    bot.button custom_id: /event_create_modal_2_(\d+)/ do |event|
      return event.respond('You don\'t have permission to do this!') unless User.find_by(discord_id: event.user.id).leader
      id = event.custom_id.match(/event_create_modal_2_(\d+)/)[1].to_i
      event_create_pt_two event, id
    end

    bot.button custom_id: /event_create_modal_3_(\d+)/ do |event|
      return event.respond('You don\'t have permission to do this!') unless User.find_by(discord_id: event.user.id).leader
      id = event.custom_id.match(/event_create_modal_3_(\d+)/)[1].to_i
      event_create_pt_three event, id
    end

    bot.button custom_id: /event_disable_(\d+)/ do |event|
      return event.respond('You don\'t have permission to do this!') unless User.find_by(discord_id: event.user.id).leader
      event.defer_update
      id = event.custom_id.match(/event_disable_(\d+)/)[1].to_i
      event_disable event, id
    end

    # A driver confirming they have their roster. Deliberately not leader-gated
    # — the person pressing it is the driver, and the only thing they can do is
    # confirm their own message.
    bot.button custom_id: /dispatch_ack_(\d+)/ do |event|
      acknowledge_dispatch event, event.custom_id.match(/dispatch_ack_(\d+)/)[1].to_i
    end

    # "Don't snipe me" / "Changed my mind". Anyone may press; the reply is
    # ephemeral so the shared message never changes for other people.
    bot.button custom_id: /\A(snipes_optout|snipes_optin)\z/ do |event|
      set_snipes_preference event, opt_out: event.custom_id == Snipes::Notice::OPT_OUT_ID
    end

    bot.button custom_id: /event_delete_(\d+)/ do |event|
      return event.respond('You don\'t have permission to do this!') unless User.find_by(discord_id: event.user.id).leader
      event.defer_update
      id = event.custom_id.match(/event_delete_(\d+)/)[1].to_i
      event_delete event, id
    end
  end

  def set_event_handlers
    @bot.member_join do |event|
      handle_member_join event
    end

    @bot.member_leave do |event|
      handle_member_leave event
    end

    # No :message filter — discordrb fixes handler attributes at registration
    # time, and the set of messages we watch changes while the bot runs. The
    # filtering is one indexed lookup in SignupOption.for_reaction.
    @bot.reaction_add do |event|
      handle_reaction_add event
    end

    @bot.reaction_remove do |event|
      handle_reaction_remove event
    end

    @bot.reaction_remove_all do |event|
      handle_reaction_remove_all event
    end

    # Every message, everywhere the bot can see; the enforcer's first check is
    # "is this the snipes channel", so this is one indexed lookup per message.
    @bot.message do |event|
      handle_message event
    end
  end

  def handle_message(event)
    Snipes::Enforcer.new(@bot).call(event.message)
  rescue StandardError => e
    warn "snipes enforcer failed: #{e.class}: #{e.message}"
  end

  def set_snipes_preference(event, opt_out:)
    result = Snipes::Preference.set(
      discord_id: event.user.id, opt_out: opt_out,
      username: event.user.username, display_name: safe_display_name(event)
    )
    event.respond(content: Snipes::Preference.reply_for(result.opt_out), ephemeral: true)
  rescue StandardError => e
    warn "snipes preference failed for #{event.user&.id}: #{e.class}: #{e.message}"
    event.respond(content: 'Something went wrong saving that — try again in a moment.', ephemeral: true)
  end

  # Every handler swallows its exceptions. discordrb logs and carries on, but a
  # typo in a service would otherwise be invisible until someone noticed the
  # board was wrong.
  def handle_reaction_add(event)
    Signup::ReactionSink.new.add(
      message_id: event.message_id,
      emoji_key: Signup::EmojiKey.from_reaction_event(event),
      discord_user_id: event.user_id,
      username: event.user&.username,
      display_name: safe_display_name(event),
      bot: event.user&.bot_account?
    )
  rescue StandardError => e
    warn "reaction_add failed: #{e.class}: #{e.message}"
  end

  def handle_reaction_remove(event)
    # Uses event.user_id (patched in), not event.user — on a remove there is no
    # member payload, so #user can cost an HTTP round trip for an id we already
    # have and only need to look up locally.
    Signup::ReactionSink.new.remove(
      message_id: event.message_id,
      emoji_key: Signup::EmojiKey.from_reaction_event(event),
      discord_user_id: event.user_id
    )
  rescue StandardError => e
    warn "reaction_remove failed: #{e.class}: #{e.message}"
  end

  def handle_reaction_remove_all(event)
    Signup::ReactionSink.new.remove_all(message_id: event.message_id)
  rescue StandardError => e
    warn "reaction_remove_all failed: #{e.class}: #{e.message}"
  end

  def safe_display_name(event)
    event.user&.display_name
  rescue StandardError
    nil
  end

  # Mark the DM confirmed, and tell the driver it landed. The button is left in
  # place but disabled, so the DM still reads as a confirmed one when they scroll
  # back to it rather than looking like it was never pressed.
  #
  # @param event [Discordrb::Events::ButtonEvent]
  # @param id [Integer] dispatch_messages.id
  def acknowledge_dispatch(event, id)
    message = DispatchMessage.find_by(id: id)
    return event.respond(content: 'That ride has been cancelled.', ephemeral: true) if message.nil?

    # A second press is not an error: Discord will happily deliver one if the
    # driver taps twice, and they should see the same confirmation either way.
    message.acknowledge!

    event.update_message(content: event.message.content) do |_, view|
      view.row do |row|
        row.button(label: 'Confirmed', style: :secondary, disabled: true,
                   custom_id: "dispatch_ack_#{id}", emoji: { name: '✅' })
      end
    end
  rescue StandardError => e
    warn "dispatch ack #{id} failed: #{e.class}: #{e.message}"
  end

  # @param event [Discordrb::Events::ButtonEvent]
  # @param id [Integer]
  # @return event creation part one modal [Discordrb::Webhooks::Modal]
  def event_create_pt_one(event, id)
    evt = Event.find id
    loc = evt.location

    event.show_modal(title: 'Part 1', custom_id: "create_event_modal_1_#{'%05d' % id}") do |modal|
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'name', label: 'Name', placeholder: evt.name, required: false)
      end
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'location', label: 'Location', placeholder: (loc&.name), required: false)
      end
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'lat', label: 'Latitude', placeholder: loc&.lat&.to_s, required: false)
      end
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'lon', label: 'Longitude', placeholder: loc&.lon&.to_s, required: false)
      end
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'channel', label: 'Channel Name', placeholder: evt.channel&.name, required: false)
      end
    end
  end

  # @param event [Discordrb::Events::ModalSubmitEvent]
  # @param id [Integer]
  # @return updated message interaction [Discordrb::Events::InteractionCreateEvent]
  def handle_event_create_pt_one(event, id)
    evt = Event.find(id)

    loc = if event.value('location') #God, please forgive me for this block
      Location.search_by_name(event.value('location')).first
    elsif event.value('lat') && event.value('lon')
      Location.search_by_coords(event.value('lat'), event.value('lon')).first
    end || @map.create_new_location(event.value('location') || { lat: event.value('lat'), lon: event.value('lon') }) || evt.location

    values = {
      name: event.value('name') || evt.name,
      location: loc,
      channel: Channel.for_rides.find_by(name: event.value('channel')) || evt.channel
    }.delete_if{ |_, value| value.nil? || (value.is_a?(String) && value.empty?) }

    evt.update(values)

    _, pt_2_button, pt_3_button, disable_button = get_changable_event_create_components event, id

    emoji, style = if !(evt.name && evt.location && evt.channel)
      [ nil, :primary ]
    else
      [ TanukiEmoji.find_by_alpha_code(':ballot_box_with_check:').codepoints, :success ]
    end

    event.update_message content: event.message.content do |_, view|
      view.row do |row|
        row.button label: 'Pt 1', style: style, custom_id: "event_create_modal_1_#{'%05d' % id}", emoji: emoji&.to_s
        row.button label: 'Pt 2', style: pt_2_button.style, custom_id: "event_create_modal_2_#{'%05d' % id}", emoji: pt_2_button.emoji&.to_s
        row.button label: 'Pt 3', style: pt_3_button.style, custom_id: "event_create_modal_3_#{'%05d' % id}", emoji: pt_3_button.emoji&.to_s
        row.button label: disable_button.label, style: disable_button.style, custom_id: "event_disable_#{'%05d' % id}", emoji: disable_button.emoji&.to_s
        row.button label: 'Delete event', style: :danger, custom_id: "event_delete_#{'%05d' % id}"
      end
    end
  end

  # @param event [Discordrb::Events::ButtonEvent]
  # @param id [Integer]
  # @return event creation part two modal [Discordrb::Webhooks::Modal]
  def event_create_pt_two(event, id)
    evt = Event.find(id)
    event.show_modal(title: 'Part 2', custom_id: "create_event_modal_2_#{'%05d' % evt.id}") do |modal|
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'start_time', label: 'Start Time', placeholder: evt.start_time, required: false)
      end
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'end_time', label: 'End Time', placeholder: evt.end_time, required: false)
      end
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'repeat', label: 'Repeat every (week/never(blank))', placeholder: evt.repeats_every, required: false)
      end
    end
  end

  # @param event [Discordrb::Events::ModalSubmitEvent]
  # @param id [Integer]
  # @return updated message interaction [Discordrb::Events::InteractionCreateEvent]
  def handle_event_create_pt_two(event, id)
    evt = Event.find(id)

    values = {
      start_time: Chronic.parse(event.value('start_time')) || evt.start_time,
      end_time: Chronic.parse(event.value('end_time')) || evt.end_time,
      repeats_every: event.value('repeat').nil? || (event.value('repeat').empty? ? 'never' : event.value('repeat').downcase) || evt.repeats_every
    }.delete_if{ |_, value| value.nil? || (value.is_a?(String) && value.empty?) }

    evt.update(values)

    pt_1_button, _, pt_3_button, disable_button = get_changable_event_create_components event, id

    emoji, style = if !(evt.start_time && evt.end_time)
      [ nil, :primary ]
    else
      [ TanukiEmoji.find_by_alpha_code(':ballot_box_with_check:').codepoints, :success ]
    end


    event.update_message content: event.message.content do |_, view|
      view.row do |row|
        row.button label: 'Pt 1', style: pt_1_button.style, custom_id: "event_create_modal_1_#{'%05d' % id}", emoji: pt_1_button.emoji&.to_s
        row.button label: 'Pt 2', style: style, custom_id: "event_create_modal_2_#{'%05d' % id}", emoji: emoji&.to_s
        row.button label: 'Pt 3', style: pt_3_button.style, custom_id: "event_create_modal_3_#{'%05d' % id}", emoji: pt_3_button.emoji&.to_s
        row.button label: disable_button.label, style: disable_button.style, custom_id: "event_disable_#{'%05d' % id}", emoji: disable_button.emoji&.to_s
        row.button label: 'Delete event', style: :danger, custom_id: "event_delete_#{'%05d' % id}"
      end
    end
  end

  # @param event [Discordrb::Events::ButtonEvent]
  # @param id [Integer]
  # @return event creation part two modal [Discordrb::Webhooks::Modal]
  def event_create_pt_three(event, id)
    evt = Event.find(id)
    event.show_modal(title: 'Part 3', custom_id: "create_event_modal_3_#{'%05d' % evt.id}") do |modal|
      modal.row do |row|
        row.text_input(style: :paragraph, custom_id: 'message', label: 'Message', placeholder: evt.message, required: false)
      end
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'reaction_1', label: 'Reaction 1 (name/character/blank)', placeholder: evt.emojis&.first&.modal_display, required: false)
      end
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'reaction_2', label: 'Reaction 2 (name/character/blank)', placeholder: evt.emojis&.second&.modal_display, required: false)
      end
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'reaction_3', label: 'Reaction 3 (name/character/blank)', placeholder: evt.emojis&.third&.modal_display, required: false)
      end
      modal.row do |row|
        row.text_input(style: :short, custom_id: 'reaction_4', label: 'Reaction 4 (name/character/blank)', placeholder: evt.emojis&.fourth&.modal_display, required: false)
      end
    end
  end

  # @param event [Discordrb::Events::ModalSubmitEvent]
  # @param id [Integer]
  # @return updated message interaction [Discordrb::Events::InteractionCreateEvent]
  def handle_event_create_pt_three(event, id)
    evt = Event.find(id)

    emojis = 1.upto(4).map do |x| #using i is for your normal cs major
      response = event.value("reaction_#{x}")
      if t_emoji = TanukiEmoji.find_by_codepoints(response)
        Emoji.find_or_create_by(name: t_emoji.name)
      elsif t_emoji = TanukiEmoji.find_by_alpha_code(":#{response.remove(':')}:")
        Emoji.find_or_create_by(name: t_emoji.name)
      elsif emoji = Emoji.find_by(name: response)
        emoji
      elsif emoji = Emoji.find_by(discord_id: response.to_i)
        emoji
      else
        nil
      end
    end.delete_if{ |value| value.nil? } || evt.emojis

    values = {
      message: event.value('message') || evt.message,
      emojis: emojis
    }.delete_if{ |_, value| value.nil? || (value.is_a?(String) && value.empty?) || (value.is_a?(Array) && value.empty?) }

    evt.update(values)

    pt_1_button, pt_2_button, _, disable_button = get_changable_event_create_components event, id

    emoji, style = if !(evt.message && evt.emojis.length > 0)
      [ nil, :primary ]
    else
      [ TanukiEmoji.find_by_alpha_code(':ballot_box_with_check:').codepoints, :success ]
    end

    # Nothing to schedule: the sign-up publisher polls every 30 seconds and
    # picks this occurrence up on its own. The call that used to be here
    # (`bot_schedule(evt)`) raised NoMethodError on a nil scheduler every time.

    event.update_message content: event.message.content do |_, view|
      view.row do |row|
        row.button label: 'Pt 1', style: pt_1_button.style, custom_id: "event_create_modal_1_#{'%05d' % id}", emoji: pt_1_button.emoji&.to_s
        row.button label: 'Pt 2', style: pt_2_button.style, custom_id: "event_create_modal_2_#{'%05d' % id}", emoji: pt_2_button.emoji&.to_s
        row.button label: 'Pt 3', style: style, custom_id: "event_create_modal_3_#{'%05d' % id}", emoji: emoji&.to_s
        row.button label: disable_button.label, style: disable_button.style, custom_id: "event_disable_#{'%05d' % id}", emoji: disable_button.emoji&.to_s
        row.button label: 'Delete event', style: :danger, custom_id: "event_delete_#{'%05d' % id}"
      end
    end
  end

  # @param event [Discordrb::Events::SubcommandBuilder]
  # @param id [Integer]
  # @return event creation part one modal [Discordrb::Webhooks::Modal]
  def event_create_message(event)
    evt = Event.create
    event.respond content: "Please fill out the following modals to create the event. All previously entered information will be shown in the text placeholders" do |_, view|
      view.row do |row|
        row.button label: 'Pt 1', style: :primary, custom_id: "event_create_modal_1_#{'%05d' % evt.id}"
        row.button label: 'Pt 2', style: :primary, custom_id: "event_create_modal_2_#{'%05d' % evt.id}"
        row.button label: 'Pt 3', style: :primary, custom_id: "event_create_modal_3_#{'%05d' % evt.id}"
        row.button label: 'Disable event', style: :danger, custom_id: "event_disable_#{'%05d' % evt.id}"
        row.button label: 'Delete event', style: :danger, custom_id: "event_delete_#{'%05d' % evt.id}"
      end
    end
  end

  # @param event [Discordrb::Events::ButtonEvent]
  # @param id [Integer]
  # @return edit message to say event is disabled [Discordrb::Events::InteractionCreateEvent]
  def event_disable(event, id)
    evt = Event.find(id)
    evt.update(disabled: !evt.disabled)

    pt_1_button, pt_2_button, pt_3_button, disable_button = get_changable_event_create_components event, id

    emoji, style, label = if disable_button.emoji
      [ nil, :danger, 'Disable event' ]
    else
      [ TanukiEmoji.find_by_alpha_code(':pause_button:').codepoints, :secondary, 'Enable event' ]
    end


    event.edit_response content: event.message.content do |_, view|
      view.row do |row|
        row.button label: 'Pt 1', style: pt_1_button.style, custom_id: "event_create_modal_1_#{'%05d' % id}", emoji: pt_1_button.emoji&.to_s
        row.button label: 'Pt 2', style: pt_2_button.style, custom_id: "event_create_modal_2_#{'%05d' % id}", emoji: pt_2_button.emoji&.to_s
        row.button label: 'Pt 3', style: pt_3_button.style, custom_id: "event_create_modal_3_#{'%05d' % id}", emoji: pt_3_button.emoji&.to_s
        row.button label: label, style: style, custom_id: "event_disable_#{'%05d' % id}", emoji: emoji&.to_s
        row.button label: 'Delete event', style: :danger, custom_id: "event_delete_#{'%05d' % id}"
      end
    end
  end

  # @param event [Discordrb::Events::ButtonEvent]
  # @param id [Integer]
  # @return delete message for event [Discordrb::Events::InteractionCreateEvent]
  def event_delete(event, id)
    evt = Event.find(id)

    # A past occurrence is the only record of who rode with whom, and
    # `has_many :rides, dependent: :destroy` would take the roster with it. Only
    # an occurrence nobody ever signed up for is safe to actually delete.
    if evt.rides.any?
      evt.update(disabled: true)
    else
      evt.destroy
    end

    event.delete_response
  end

  # @param event [Discordrb::Events::ModalSubmitEvent]
  # @param id [Integer]
  # @return part 1, part 2, part3, and disable buttons [Array<Discordrb::Components::Button>]
  def get_changable_event_create_components(event, id)
    [
      event.get_component("event_create_modal_1_#{'%05d' % id}"),
      event.get_component("event_create_modal_2_#{'%05d' % id}"),
      event.get_component("event_create_modal_3_#{'%05d' % id}"),
      event.get_component("event_disable_#{'%05d' % id}")
    ]
  end

  # @param user [User]
  def handle_login_code(user)
    code = passgen
    user.update(password: code, password_confirmation: code)
    @bot.user(user.discord_id).dm("Here is your login code: #{code}")
  end

  # @param event [Discordrb::Events::ServerMemberAddEvent]
  def handle_member_join(event)
    return unless Server.find_by(name: ABIDE_SERVER_NAME)&.discord_id == event.server.id #we only care if it's the abide server
    User.find_or_create_by(discord_id: event.member.id) do |user|
      pass = passgen
      user.username = event.member.username
      user.name = event.member.display_name
      user.leader = event.member.permission?(:administrator) || event.member.role?('Leaders') || event.member.role?('Coordinator')
      user.password = pass
      user.password_confirmation = pass
    end
  end

  # Deliberately does not delete anything.
  #
  # This used to be `User.find_by(discord_id: …).destroy`, and with
  # `User has_many :rides, dependent: :destroy` that took every historical ride
  # with it — so every graduating senior wiped themselves out of every past
  # roster each May, along with their clash pairs. It also raised NoMethodError
  # on nil for anyone the bot had never recorded.
  #
  # Keeping the row costs one stale name in a picker; deleting it costs the
  # history the whole dashboard is built on.
  #
  # @param event [Discordrb::Events::ServerMemberDeleteEvent]
  def handle_member_leave(event)
    return unless Server.find_by(name: ABIDE_SERVER_NAME)&.discord_id == event.server.id

    user = User.find_by(discord_id: event.member.id)
    return if user.nil?

    warn "#{user.display_name} left the server; keeping their record and ride history"
  rescue StandardError => e
    warn "member_leave handler failed: #{e.class}: #{e.message}"
  end
end

# i[' ]?a?m (.+)
