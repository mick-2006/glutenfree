local ltn = require('scripts.ltn')
local trains = require('scripts.train')
local combinator = require('scripts.combinator')

local speaker = {}

--

function speaker.init()
  global.on_nth_ticks = nil

  global.entries = {}
  global.deathrattles = global.deathrattles or {}

  global.deliveries = {}
  global.logistic_train_stops = {}
  global.deliveries_table_was_previously_empty = true

  --

  global.train_stops = nil
  global.train_stop_at = nil

  --

  global.entangled = {}

  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered{type = 'train-stop', name = 'logistic-train-stop'}) do
      speaker.add_speaker_to_ltn_stop(entity) -- resets any signals to their default until the the next dispatch
    end
  end

end

function speaker.on_created_entity(event)
  local entity = event.created_entity or event.entity or event.destination
  if entity.name ~= 'logistic-train-stop' then return end

  speaker.add_speaker_to_ltn_stop(entity)
end

function speaker.add_speaker_to_ltn_stop(entity)
  local speakerpole = nil

  local multiblock = entity.surface.find_entities(ltn.search_area(entity))
  for _, mb_entity in ipairs(multiblock) do
    if mb_entity.name == "entity-ghost" then
      if mb_entity.ghost_name == 'logistic-train-stop-announcer' then
        _, speakerpole = mb_entity.revive()
      end
    else
      if mb_entity.name == 'logistic-train-stop-announcer' then
        speakerpole = mb_entity
      end
    end
  end

  speakerpole = speakerpole or entity.surface.create_entity({
    name = 'logistic-train-stop-announcer',
    position = ltn.pos_for_speaker(entity),
    force = entity.force,
  })

  speakerpole.operable = false
  speakerpole.destructible = false

  -- disconnect any/only coppy wires
  speakerpole.disconnect_neighbour()

  -- mark speaker pole for death if the station dissapears
  global.deathrattles[script.register_on_entity_destroyed(entity)] = {speakerpole}

  local red_signal = speakerpole.surface.find_entity('logistic-train-stop-announcer-red-signal', speakerpole.position) or
  speakerpole.surface.create_entity({
    name = 'logistic-train-stop-announcer-red-signal',
    position = speakerpole.position,
    force = speakerpole.force,
  })

  local green_signal = speakerpole.surface.find_entity('logistic-train-stop-announcer-green-signal', speakerpole.position) or
  speakerpole.surface.create_entity({
    name = 'logistic-train-stop-announcer-green-signal',
    position = speakerpole.position,
    force = speakerpole.force,
  })

  red_signal.operable = false
  green_signal.operable = false

  -- mark both color combinators for death if the speaker pole dissapears
  global.deathrattles[script.register_on_entity_destroyed(speakerpole)] = {red_signal, green_signal}

  speakerpole.connect_neighbour({
    target_entity = red_signal,
    wire = defines.wire_type.red,
  })

  speakerpole.connect_neighbour({
    target_entity = green_signal,
    wire = defines.wire_type.green,
  })

  global.entries[entity.unit_number] = {
    speakerpole = speakerpole,
    red_signal = red_signal,
    green_signal = green_signal, 
  }
  
  red_signal.get_control_behavior().parameters = {{index = 1, signal = {type="virtual", name="signal-red"}, count = 1 }}
  green_signal.get_control_behavior().parameters = {{index = 1, signal = {type="virtual", name="signal-green"}, count = 1 }}
end

-- conveniently gets called when a temporary schedule gets removed,
-- and since we want to remove the 'announcement' when the train arrives,
-- we just have to check which station the train is at when it gets taken off.
function speaker.on_train_schedule_changed(event)
  -- game.print("schedule changed @ " .. event.tick)

  if not global.deliveries then return end -- ltn event race condition
  if not global.entangled then return end -- ltn event race condition

  -- filter out this train id during debugging
  -- if event.train.id ~= 1236 then return end (nauvis stone)
  -- if event.train.id ~= 4748 then return end (thermofluid)

  local already_updated = {}

  -- update all the stations where this train caused red/green signals ^-^
  for _, station in ipairs(trains.entangled_with_stations(event.train)) do
    speaker.announce(station)
    already_updated[station.unit_number] = true
  end

  -- not an LTN train, or delivery not yet registered here
  if not global.deliveries[event.train.id] then return end
  local delivery = global.deliveries[event.train.id]

  local provider = global.logistic_train_stops[delivery.from_id]
  if provider and not already_updated[provider.entity.unit_number] then speaker.announce(provider.entity) end

  local requester = global.logistic_train_stops[delivery.to_id]
  if requester and not already_updated[requester.entity.unit_number] then speaker.announce(requester.entity) end
end

-- update the speakerpole signals
function speaker.announce(entity)
  local entry = global.entries[entity.unit_number]
  if not entry then return end

  local red = {}
  local green = {}

  -- entity.surface.create_entity({
  --   name = "flying-text",
  --   position = entity.position,
  --   text = "announcing:",
  -- })

  for _, train in ipairs(entity.get_train_stop_trains()) do

    local delivery = global.deliveries[train.id]
    if delivery then

      -- is the train still [underway] to here?
      if trains.is_inbound(train, entity) then

        -- sum any/all the items due for pickup
        if delivery.from_id == entity.unit_number then
          for what, count in pairs(delivery.shipment) do
            red[what] = (red[what] or 0) + count
          end
          trains.entangle_with_station(train, entity)
        end

        -- sum any/all the items due for dropoff
        if delivery.to_id == entity.unit_number then
          for what, count in pairs(delivery.shipment) do
            green[what] = (green[what] or 0) + count
          end
          trains.entangle_with_station(train, entity)
        end
      end

    end
  end

  -- print(serpent.block({
  --   red = red,
  --   green = green,
  -- }))

  if entry.red_signal.valid then
    entry.red_signal.get_control_behavior().parameters = combinator.parameters_from_shipment(red)
  else
    game.print('red signal no longer valid: ' .. entity.unit_number)
  end

  if entry.green_signal.valid then
    entry.green_signal.get_control_behavior().parameters = combinator.parameters_from_shipment(green)
  else
    game.print('green signal no longer valid: ' .. entity.unit_number)
  end
end

function speaker.on_entity_destroyed(event)
  if not global.deathrattles[event.registration_number] then return end

  for _, entity in ipairs(global.deathrattles[event.registration_number]) do
    entity.destroy()
  end

  global.deathrattles[event.registration_number] = nil
end

-- <ltn events>
function speaker.on_stops_updated(event)
  -- print('on_stops_updated_event @ ' .. event.tick)
  global.logistic_train_stops = event.logistic_train_stops
end

function speaker.on_dispatcher_updated(event)
  -- game.print('on_dispatcher_updated @ ' .. event.tick)
  global.deliveries = event.deliveries

  if global.deliveries_table_was_previously_empty then
    global.deliveries_table_was_previously_empty = false

    -- we now have all deliveries, update all trains:
    for train_id, delivery in pairs(global.deliveries) do
      speaker.on_train_schedule_changed({train = delivery.train})
    end
  end
end

function speaker.on_delivery_created(event)
  -- game.print('on_delivery_created @ ' .. event.tick)
  global.deliveries[event.train.id] = event

  -- train fired the schedule change event one tick ago:
  speaker.on_train_schedule_changed({train = event.train})
end
-- </ltn events>

-- garbage collection
function speaker.every_10_minutes()
  for unit_number, entry in pairs(global.entries or {}) do
    if not entry.speakerpole.valid then
      global.entries[unit_number] = nil
    end
  end
end

return speaker
