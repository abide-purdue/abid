require_relative 'components'
require_relative 'board_helpers'

# "WAITING FOR A RIDE" — the left column. Dropping a rider here releases them
# back to the queue, which is how the design's `poolDrop` works.
class Components::BoardQueue < Phlex::HTML
  include BoardHelpers

  def initialize(board:, leader: false, tab: :details)
    @board = board
    @leader = leader
    @tab = tab
  end

  def view_template
    div(
      class: 'flex-none w-[272px] border-r border-line bg-surface-sunk flex flex-col min-h-0',
      data_drop_zone: 'queue',
      data_driver_ride_id: ''
    ) do
      queue_head
      queue_body
    end
  end

  private

  def queue_head
    div(class: 'px-3.5 pt-3.5 pb-2.5 flex-none flex flex-col gap-2.5') do
      div(class: 'flex items-baseline gap-2') do
        span(class: 'board-label') { 'Waiting for a ride' }
        span(class: 'font-mono text-[11.5px] font-semibold text-count') { @board.pool_count.to_s }
      end
      search_form
    end
  end

  # GET so the filter is bookmarkable and survives a no-JS submit.
  def search_form
    form(method: 'get', action: path('/board'), data_board_search: true) do
      input(type: 'hidden', name: 'event_id', value: @board.event.id)
      input(type: 'hidden', name: 'tab', value: 'roster') if @tab == :roster
      input(
        type: 'search',
        name: 'q',
        value: @board.query,
        placeholder: 'Filter by name or zone',
        class: 'board-input text-[12.5px] py-2',
        autocomplete: 'off'
      )
    end
  end

  def queue_body
    div(class: 'flex-1 overflow-y-auto px-3.5 pb-3.5 flex flex-col gap-3.5') do
      @board.queue_groups.each { |group| zone_group(group) }
      empty_note if @board.visible_pool.empty?
      not_coming if @board.out_riders.any?
    end
  end

  def zone_group(group)
    div(class: 'flex flex-col gap-[5px]') do
      div(class: 'flex items-baseline gap-1.5 px-0.5') do
        span(class: 'font-mono text-[10px] font-semibold tracking-[.07em] text-accent') { group[:zone] }
        span(class: 'font-mono text-[10px] text-ink/60') { group[:count].to_s }
      end
      group[:riders].each { |rider| rider_card(rider) }
    end
  end

  def rider_card(rider)
    selected = @board.selected_ride_id == rider.id

    div(
      class: [
        'flex items-center gap-2 px-2.5 py-[7px] rounded-[7px] border transition-colors',
        selected ? 'bg-ink text-ink-invert border-ink' : 'bg-surface text-ink border-line hover:border-accent'
      ].join(' '),
      draggable: @leader.to_s,
      data_ride_id: rider.id,
      data_draggable_rider: @leader.to_s
    ) do
      a(href: board_url(sel: (selected ? nil : rider.id), focus: rider.id), class: 'flex-1 flex flex-col gap-px min-w-0 no-underline text-inherit') do
        span(class: 'font-semibold text-[12.5px] capitalize flex items-center gap-1.5') do
          plain rider.display_name
          elsewhere_badge(rider)
          guest_badge(rider)
        end
        if rider.address.present?
          span(class: 'text-[10.5px] opacity-[.78] whitespace-nowrap overflow-hidden text-ellipsis') { rider.address }
        end
      end
      noshow_button(rider) if @leader
    end
  end

  def noshow_button(rider)
    action_form('toggle-out', ride_id: rider.id, class: 'contents') do
      button(
        type: 'submit',
        title: 'mark not coming',
        class: 'border-0 bg-transparent text-inherit opacity-60 hover:opacity-100 font-mono text-xs font-semibold cursor-pointer px-1 py-0.5'
      ) { '✕' }
    end
  end

  def empty_note
    div(class: 'px-1 py-[18px] text-[12.5px] leading-[1.55] text-ink/65') do
      if @board.query.present?
        plain 'Nobody in the queue matches that filter.'
      else
        plain 'Everyone has a ride. New sign-ups land here automatically.'
      end
    end
  end

  def not_coming
    div(class: 'flex flex-col gap-[5px] pt-1 border-t border-line') do
      div(class: 'board-label pt-2 px-0.5') { 'Not coming' }
      @board.out_riders.each { |rider| not_coming_row(rider) }
    end
  end

  def not_coming_row(rider)
    action_form('toggle-out', ride_id: rider.id, class: 'contents') do
      button(
        type: 'submit',
        title: 'put back in the queue',
        disabled: !@leader,
        class: 'flex items-center gap-[7px] px-2.5 py-1.5 rounded-[7px] cursor-pointer text-[12.5px] ' \
               'text-ink/70 line-through capitalize text-left w-full bg-transparent border-0 hover:bg-ink/5'
      ) { rider.display_name }
    end
  end
end
