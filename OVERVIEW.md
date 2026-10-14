# abid — Project Overview

**abid** is the Discord bot and companion web interface for the Abide CF Discord
server. Its main job is **organizing carpools for events**. Leaders build an event
in Discord. At a scheduled time the bot posts a "rides" message with reaction
emojis. Later it collects the driver and rider reactions, matches riders to nearby
drivers, works out pickup routes, and DMs everyone their assignment.

## Tech stack

| Area | Tools |
| --- | --- |
| Language | Ruby 3.4 |
| Discord | [`discordrb`](https://github.com/shardlab/discordrb) (main branch): slash commands, buttons, select menus, modals |
| Database | PostgreSQL 16 via ActiveRecord 8 (`sinatra-activerecord` for migrations and rake tasks) |
| Scheduling | `rufus-scheduler` (one-off and weekly cron jobs), `chronic` (natural-language time parsing) |
| Maps / routing | OpenStreetMap Nominatim (geocoding), public OSRM server (trip/route optimization) |
| Web | Sinatra + Phlex views on Puma, Tailwind CSS, webpack |
| Auth | `bcrypt` (`has_secure_password`); one-time codes from `passgen` |
| Deploy | Docker multi-stage image → GHCR → `docker compose` over SSH (GitHub Actions) |

All times use the `America/Indiana/Indianapolis` time zone and are stored in UTC.

## Repository layout

```
app.rb, config.ru        Sinatra web app (login + home page)
views/                   Phlex components and pages (layout, login, home)
src/, public/            Frontend JS (dark mode) and Tailwind CSS sources and builds
bot/
  hfile.rb               Boot file: DB connection, models, patches, Map, time zone
  run.rb                 Bot entrypoint (signal handling, keep-alive loop)
  app_manager.rb         Wires together the Bot, Setup, and Scheduler
  setup.rb               Syncs Discord servers, channels, emojis, roles, and users into the DB at startup
  bot.rb                 Slash command registration and handlers, member join/leave
  abide_event_manager/
    abide_event_handlers.rb  Button, select-menu, and modal handlers for the event dashboard
    event_draft.rb           In-memory store for events still being built
    helpers/                 Draft lifecycle, dashboard embeds and modals, unique naming
    scheduler/scheduler.rb   Posts and collects rides messages on schedule
    scheduler/matcher.rb     Matches riders to drivers and optimizes routes
map/map.rb               OSM/OSRM wrapper (geocoding, reverse geocoding, trips, routes)
models/                  ActiveRecord models
patches/                 Monkey-patches for discordrb and views (hybrid prefix/slash commands are unfinished)
db/migrate, db/schema.rb Migrations (numbered 100–1702) and the current schema
db/seeds.rb              Seeds Discord credentials and IDs from a gitignored config.yml
bin/bot, bin/dev         Run the bot / run the web app (foreman + Procfile.dev)
Dockerfile, docker-compose*.yml, DEPLOY.md   Container build and production deployment
```

## Data model

- **Server → Channel → Event**: Discord guilds and their channels. Events belong
  to a channel, and a server reaches its events through its channels. Commands
  only see the events of the server they were run in.
- **Event**: name, message text, `start_time`/`end_time`, `message_rides_at`
  (when to post), `collect_rides_at` (when to tally), optional
  `repeats_every: 'week'`, location, organizer, and a status enum:
  `unpublished`, `scheduled`, `active`, `completed`, `cancelled`. Published
  events must have all four times, in a valid order.
- **Emoji**: reaction emojis attached to an event. By convention the first is
  the **driver** emoji and the second is the **rider** emoji.
- **User**: a Discord member. Fields: `leader` flag, `capacity` (seats),
  `location`, roles (`Drivers`, `Riders`, `Coordinator`, …), and a password
  digest for web login.
- **EventSignup**: a user's reaction to an event (`driver` / `rider` / `maybe`).
- **RideAssignment**: a rider ↔ driver pairing for an event, plus the stored route (jsonb).
- **Location**: name, aliases, lat/lon.
- **Role**, **DiscordInfo**: Discord roles, and the bot token, app ID, and public key.

## How the bot works

### Startup (`AppManager`)
1. Reads the token from `DISCORD_TOKEN` (used for a beta bot) or from the
   `discord_infos` row.
2. `Bot` registers the per-server slash commands and the interaction handlers,
   then connects.
3. `Setup` syncs channels, emojis, roles, and non-bot members into the database.
   It drops any `Server` rows for servers the bot is no longer in.
4. `Scheduler` reloads the jobs for every `scheduled` event and checks every
   5 minutes for events that still need scheduling.

### Slash commands
| Command | Who can use it | What it does |
| --- | --- | --- |
| `/event create name:` | leaders and coordinators | Opens an interactive builder dashboard backed by an in-memory `EventDraft` |
| `/event show name:` | leaders and coordinators | Shows an event; editors also get management buttons (unpublish, republish, cancel, delete, duplicate) |
| `/event list [status]` | anyone (only leaders and coordinators can list `unpublished`) | Lists events |
| `/event delete name:` | leaders and coordinators | Deletes an unpublished event |
| `/event nuke` | hard-coded owner ID | Deletes every event |
| `/login` | leaders | DMs a one-time password for the web interface |
| `/debug` | leaders | Opens an IRB session on the host. Other users who try it trigger a DM to the mods |
| `/hello` | anyone | Says hello |

The builder dashboard uses buttons that open modals for **basics**, **timing**,
and **reactions**, plus a channel select menu. A draft stays in memory until the
user clicks **Publish** (saved and scheduled) or **Save as Unpublished**.

### Rides pipeline (`Scheduler` + `Matcher`)
1. **At `message_rides_at`**: the bot posts the event's message in its channel
   and adds the event's emojis as reactions. Weekly events use a cron job
   instead of a one-off job.
2. **At `collect_rides_at`**: the bot reads the reactions. People who reacted
   with the driver emoji and have the `Drivers` role count as drivers. People
   who reacted with the rider emoji and have the `Riders` role count as riders,
   unless they are already drivers. Each one gets an `EventSignup` record.
3. **Matching**: each rider gets their 3 nearest drivers by straight-line
   distance. A greedy pass then fills drivers up to their `capacity`. OSRM's
   trip service orders each driver's pickups, and the result is saved as
   `RideAssignment` records.
4. **Notifications**: riders are DMed the name of their driver. Drivers are
   DMed their pickup route and rider list. A summary that includes any
   unassigned riders goes to the mods (`ian`, `alan`, `bfm`).

### Member events
On the main "Abide" server, a member who joins gets a `User` record. Admins and
members with the `Leaders` or `Coordinator` role are marked as leaders. A member
who leaves has their `User` record deleted.

## Web interface
This part is minimal so far. It is a Sinatra app with session-cookie auth: a
login page (username plus the code sent by `/login`) and a placeholder home
page. All routes except `/login` require a session. Locally it runs on port
4455 (Puma on 5544 under foreman), with Tailwind and webpack watchers.

## Running locally
1. `yarn install && bundle install`
2. `docker-compose up` to start Postgres (`postgres` / `password` on 5432)
3. Copy `.env.local.example` to `.env.local`. Set `DISCORD_TOKEN` to point at a
   beta Discord app, and `CONFIG_FILE` for seeding.
4. `rake db:migrate db:seed` (seeding needs the gitignored `config.yml`)
5. `bin/bot` for the bot, `bin/dev` for the web interface

The web app needs `SESSION_SECRET` or a `.session_secret` file.

## Deployment
Pushing to `main` (or running the **Deploy** workflow) builds one image,
`ghcr.io/wobschalli/abid:<sha>`, and restarts three containers over SSH: `db`
(Postgres 16), `web` (Puma; runs migrations on boot), and `bot` (`bin/bot`;
starts after `web`). Rolling back means pinning `APP_IMAGE` to an earlier sha.
See [DEPLOY.md](DEPLOY.md) for setup, secrets, and day-to-day operations.

## Known issues / rough edges
- **`bot/abide_event_manager/scheduler/scheduler.rb` does not parse.** The
  `def send_scheduled_message(event)` line is missing (around line 158), so
  `ruby -c` reports a syntax error and the bot will fail to boot.
- Mod DMs are hard-coded to the users named `ian`, `alan`, and `bfm`, and
  `/event nuke` is tied to a single hard-coded Discord user ID.
- Event drafts live only in memory and are lost when the bot restarts.
- Matching is greedy and uses straight-line distance, not road distance.
  Geocoding is limited to a Tippecanoe County bounding box, and the code calls
  the public OSRM demo server.
- Hybrid prefix/slash command support in `patches/bot.rb` is unfinished.
- There is no test suite.
