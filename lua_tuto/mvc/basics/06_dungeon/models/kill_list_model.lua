-- kill_list_model.lua
-- 지금까지 처치한 적 이름 목록. QuestModel 처럼 GameModel 을 전혀 모르고,
-- 이벤트 버스의 "enemy_killed" 만 구독해서 스스로 기록한다.
-- (도망친 적은 "fled" 이벤트라 기록되지 않는다)

local KillListModel = {}
KillListModel.__index = KillListModel

function KillListModel.new(bus)
  local self = setmetatable({ names = {} }, KillListModel)
  bus:on("enemy_killed", function(data)
    self:add(data.name)
  end)
  return self
end

function KillListModel:add(name)
  self.names[#self.names + 1] = name
end

return KillListModel
