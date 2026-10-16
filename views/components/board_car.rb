require_relative 'components'
require_relative 'board_helpers'

# One car column. Riders can be dragged in, or click-to-seat when a rider is
# selected in the queue.
class Components::BoardCar < Phlex::HTML
  include BoardHelpers

  def initialize(car:, board:, leader: false, tab: :details)
    @car = car
    @board = board
    @leader = leader
    @tab = tab
    @selected = board.selected
    @fit = board.selected ? car.fit_for(board.selected) : nil
  end

  def view_template
    div(
      class: card_classes,
      data_drop_zone: 'car',
      data_driver_ride_id: @car.id
    ) do
      car_header
      capacity_bar
      div(class: 'mt-2.5 overflow-hidden rounded-b-[10px]') do
        @car.passengers.each { |p| passenger_row(p) }
        drop_hint if @car.empty?
      end
    end
  end

  private

  # While a rider is selected the design dims cars that can't take them and
  # outlines the closest match.
  def card_classes
    border =
      if @car.over?
        'border-warn'
      elsif @fit == :closest
        'border-accent'
      else
        'border-line'
      end

    dim = @fit == :full ? 'opacity-[.42]' : 'opacity-100'

    "flex flex-col bg-surface border #{border} rounded-[10px] self-start #{dim} transition-[opacity,border-color] duration-150"
  end

  def car_header
    div(class: 'flex items-start gap-2 px-3 pt-[11px] pb-[9px]') do
      div(class: 'flex-1 flex flex-col gap-0.5 min-w-0') do
        div(class: 'flex items-baseline gap-[7px] flex-wrap') do
          seat_link
          elsewhere_badge(@car.ride)
          span(class: fit_pill_class(@fit)) { BoardHelpers::FIT_LABELS[@fit] } if @fit
          dispatch_badge
        end
        span(class: 'board-meta') { "#{@car.zone || 'no zone'} · #{@car.seat_text}" }
      end
      edit_link
    end
  end

  # Clicking the car seats the selected rider; with nothing selected it opens the
  # driver in the details rail.
  def seat_link
    if @selected && @leader
      action_form('assign', ride_id: @selected.id, driver_ride_id: @car.id, class: 'contents') do
        button(
          type: 'submit',
          class: 'border-0 bg-transparent p-0 cursor-pointer font-bold text-sm capitalize text-ink text-left'
        ) { @car.name }
      end
    else
      a(href: board_url(focus: @car.id), class: 'font-bold text-sm capitalize text-ink no-underline hover:text-accent') { @car.name }
    end
  end

  # Whether this driver has been told, and whether anything has changed since.
  #
  # Every state is a word, in the same slot, so reading down a column of cars
  # answers "who has not come back to me?" by scanning one place. Confirmed was
  # briefly a green dot; it is the state you look for most, and a dot made it
  # the one state you could not read.
  #
  # Green carries it as well, but never alone — "confirmed" and "sent" differ in
  # text, not just colour, so the distinction survives a colourblind reader, a
  # greyscale print of the board, and a screenshot in a group chat.
  DISPATCH_BADGES = {
    queued: ['bg-ink/[.07] text-ink/70', 'sending…'],
    sent: ['bg-ink/[.07] text-ink/70', 'sent'],
    confirmed: ['bg-accent-tint text-accent', '✓ confirmed'],
    changed: ['bg-warn-tint text-warn-ink', 'changed'],
    failed: ['bg-danger-tint text-danger', 'dm failed']
  }.freeze

  def dispatch_badge
    state = @board.dispatch_status.state_for(@car.ride)
    style, label = DISPATCH_BADGES[state]
    return if style.nil? # :never — no badge until something has been sent

    span(
      title: badge_title(state),
      class: "font-mono text-[9.5px] font-semibold tracking-[.06em] px-[7px] py-[3px] rounded-[5px] #{style}"
    ) { label }
  end

  # The badge says the state; the tooltip says when, which is the follow-up
  # question every time ("has he confirmed since I moved Devon?").
  def badge_title(state)
    return nil unless state == :confirmed

    at = @board.dispatch_status.acknowledged_at_for(@car.ride)
    return 'pressed “Got it” on their DM' if at.nil?

    "pressed “Got it” at #{at.strftime('%a %-l:%M %p')}"
  end

  def edit_link
    a(
      href: board_url(focus: @car.id),
      title: 'edit driver details',
      class: 'border-0 bg-transparent text-ink/55 hover:text-ink font-mono text-[13px] font-semibold cursor-pointer px-0.5 no-underline'
    ) { '⋯' }
  end

  def capacity_bar
    div(class: 'h-[3px] flex-none mx-3 rounded-full bg-ink/[.12] overflow-hidden') do
      div(
        class: "h-full #{@car.over? ? 'bg-warn' : 'bg-accent'}",
        style: "width: #{@car.fill_percent}%"
      )
    end
  end

  def passenger_row(passenger)
    focused = @board.focus_ride_id == passenger.id

    div(
      class: [
        'flex items-center gap-2 px-[11px] py-1.5 border-t border-line-soft',
        focused ? 'bg-ink/[.06]' : 'bg-transparent'
      ].join(' '),
      draggable: @leader.to_s,
      data_ride_id: passenger.id,
      data_draggable_rider: @leader.to_s
    ) do
      a(href: board_url(focus: passenger.id), class: 'flex-1 flex flex-col gap-px min-w-0 no-underline text-ink') do
        span(class: 'font-medium text-[12.5px] capitalize flex items-center gap-1.5') do
          plain passenger.display_name
          elsewhere_badge(passenger)
          guest_badge(passenger)
        end
        if passenger.address.present?
          span(class: 'text-[10.5px] text-ink/70 whitespace-nowrap overflow-hidden text-ellipsis') { passenger.address }
        end
      end

      if @leader
        release_button(passenger)
        noshow_button(passenger)
      end
    end
  end

  def release_button(passenger)
    action_form('assign', ride_id: passenger.id, driver_ride_id: '', class: 'contents') do
      button(
        type: 'submit',
        title: 'back to queue',
        class: 'border-0 bg-transparent text-ink/55 hover:text-ink font-mono text-xs font-semibold cursor-pointer px-1 py-0.5'
      ) { '↩' }
    end
  end

  def noshow_button(passenger)
    action_form('toggle-out', ride_id: passenger.id, class: 'contents') do
      button(
        type: 'submit',
        title: 'mark not coming',
        class: 'border-0 bg-transparent text-ink/55 hover:text-danger font-mono text-xs font-semibold cursor-pointer px-1 py-0.5'
      ) { '✕' }
    end
  end

  def drop_hint
    div(class: 'mx-3 mt-1.5 mb-3 p-3 border border-dashed border-line rounded-[7px] text-[11.5px] text-ink/60 text-center') do
      'drop riders here'
    end
  end
end
