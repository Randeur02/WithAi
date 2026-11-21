-- player_model.lua
-- 플레이어 한 명의 상태(체력, 공격력, 장비, 골드)와 규칙(체력 상한, 사망 판정).

local PlayerModel = {}
PlayerModel.__index = PlayerModel

-- def: { name, maxHp, attack }
function PlayerModel.new(def)
  return setmetatable({
    name = def.name or "용사",
    hp = def.maxHp,
    maxHp = def.maxHp,
    baseAttack = def.attack,
    weapon = nil, -- { name, power }
    gold = 0,
  }, PlayerModel)
end

function PlayerModel:getAttack()
  return self.baseAttack + (self.weapon and self.weapon.power or 0)
end

function PlayerModel:takeDamage(amount)
  self.hp = math.max(0, self.hp - amount)
end

-- 실제로 회복된 양을 돌려준다.
function PlayerModel:heal(amount)
  local before = self.hp
  self.hp = math.min(self.maxHp, self.hp + amount)
  return self.hp - before
end

function PlayerModel:equip(weapon)
  self.weapon = { name = weapon.name, power = weapon.power }
end

function PlayerModel:addGold(amount)
  self.gold = self.gold + amount
end

-- 상점 구매용. 사용자에게 보일 실패 이유는 GameModel:buy 가 먼저 검사해 돌려주고,
-- 여기서는 골드가 음수가 되는 잘못된 호출을 막는 마지막 방어선만 둔다.
function PlayerModel:spendGold(amount)
  assert(amount <= self.gold, string.format("골드 부족: 보유 %d, 차감 %d", self.gold, amount))
  self.gold = self.gold - amount
end

function PlayerModel:isDead()
  return self.hp <= 0
end

return PlayerModel
