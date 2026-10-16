# Plus-ones (issue #22): people the coordinator adds who are not in the
# Discord — a roommate, a friend visiting for the weekend.
#
# A plus-one is a ride with a name and no user. Creating a User instead would
# have meant inventing a Discord id for someone who has none, and every
# member sync, census import and Members count would have had to learn to
# step around them. On the ride, they exist for exactly one occasion, which
# is all a plus-one is.
#
# host_ride_id links them to whoever brought them: same car, same pickup. If
# the host's ride goes away the link is cleared rather than the guest deleted
# — they still need a lift, and the coordinator should see them.
class AddPlusOnesToRides < ActiveRecord::Migration[8.0]
  def change
    change_column_null :rides, :user_id, true
    add_column :rides, :guest_name, :string
    add_reference :rides, :host_ride, foreign_key: { to_table: :rides, on_delete: :nullify }
    add_check_constraint :rides, 'user_id IS NOT NULL OR guest_name IS NOT NULL',
                         name: 'rides_have_a_person'
  end
end
