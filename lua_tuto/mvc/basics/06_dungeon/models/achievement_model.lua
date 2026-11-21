-- achievement_model.lua
-- 업적: 처치로 얻은 골드를 누적해, 기준 이상이 되면 한 번만 "achievement_unlocked" 를 발행한다.
-- GameModel·PlayerModel 을 모른다. 필요한 골드 값은 "enemy_killed" 이벤트의 data.gold 로 받는다.
-- (플레이어 보유 골드가 아니라 "처치 골드 누적"이므로 상점에서 써도 줄지 않는다)
-- 기준값(gold)과 문구(text)는 데이터 파일이 정한다.

local AchievementModel = {}
AchievementModel.__index = AchievementModel

-- defs: { { id, text, gold }, ... }
function AchievementModel.new(bus, defs)
  local self = setmetatable({ bus = bus, earnedGold = 0, achievements = {} }, AchievementModel)
  for _, def in ipairs(defs or {}) do
    assert(type(def.gold) == "number", "업적 기준 골드(gold)는 숫자여야 합니다: " .. tostring(def.id))
    self.achievements[#self.achievements + 1] = { id = def.id, text = def.text, gold = def.gold, unlocked = false }
  end
  bus:on("enemy_killed", function(data)
    self:addEarnedGold(data.gold or 0)
  end)
  return self
end

function AchievementModel:addEarnedGold(amount)
  self.earnedGold = self.earnedGold + amount
  for _, achievement in ipairs(self.achievements) do
    if not achievement.unlocked and self.earnedGold >= achievement.gold then
      achievement.unlocked = true
      self.bus:emit("achievement_unlocked", { id = achievement.id, text = achievement.text })
    end
  end
end

return AchievementModel
