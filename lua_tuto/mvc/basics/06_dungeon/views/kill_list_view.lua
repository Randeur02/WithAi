-- kill_list_view.lua
-- 처치한 적 목록 패널. 읽는 모델: kills (KillListModel)

local KillListView = { title = "처치 목록" }
KillListView.__index = KillListView

function KillListView.new()
  return setmetatable({}, KillListView)
end

function KillListView:lines(game)
  local names = game.kills.names
  if #names == 0 then
    return { "(아직 없음)" }
  end
  return { string.format("%s  (%d마리)", table.concat(names, ", "), #names) }
end

return KillListView
