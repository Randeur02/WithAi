-- game_model.lua
-- 루트 Model. 작은 모델들을 "소유"하고, 여러 모델에 걸친 규칙(전투, 아이템 효과, 모드 전환)을 담당한다.
--
--   GameModel ─┬─ PlayerModel
--              ├─ InventoryModel
--              ├─ DungeonModel
--              ├─ EnemyModel (전투 중에만)
--              ├─ QuestModel  ◀─┐ 이벤트 버스로만 연결
--              └─ LogModel    ◀─┘ (GameModel 은 emit 만 한다)
--
-- mode: "explore" | "battle" | "inventory" | "gameover" | "victory"
--       + "shop" (문제4: 상점 방에서 buy / leaveShop)
-- 모든 행동 메서드는 성공하면 true, 실패하면 false, 이유 를 돌려준다.

local EventBus = require("models.event_bus")
local PlayerModel = require("models.player_model")
local EnemyModel = require("models.enemy_model")
local InventoryModel = require("models.inventory_model")
local DungeonModel = require("models.dungeon_model")
local QuestModel = require("models.quest_model")
local LogModel = require("models.log_model")
local KillListModel = require("models.kill_list_model")
local AchievementModel = require("models.achievement_model")

local GameModel = {}
GameModel.__index = GameModel

-- data: { player = {...}, rooms = {...}, quests = {...}, inventoryCapacity, logLimit }
function GameModel.new(data)
  local self = setmetatable({}, GameModel)
  self.bus = EventBus.new()
  self.log = LogModel.new(self.bus, data.logLimit)
  self.quests = QuestModel.new(self.bus, data.quests)
  self.kills = KillListModel.new(self.bus)
  self.achievements = AchievementModel.new(self.bus, data.achievements)
  self.player = PlayerModel.new(data.player)
  self.inventory = InventoryModel.new(data.inventoryCapacity)
  self.dungeon = DungeonModel.new(data.rooms)
  self.enemy = nil
  self.mode = "explore"
  self.returnMode = nil
  self.shop = nil -- 상점 모드일 때 현재 상점 방 데이터
  -- 상점 방 진입: explore() 를 고치지 않고, explore() 가 발행하는 room_entered 를 구독한다.
  self.bus:on("room_entered", function()
    self:enterShopIfAny()
  end)
  return self
end

function GameModel:isOver()
  return self.mode == "gameover" or self.mode == "victory"
end

local function requireMode(self, mode)
  if self.mode ~= mode then
    return false, "지금은 할 수 없습니다 (현재: " .. self.mode .. ")"
  end
  return true
end

-- ── 탐험 ───────────────────────────────────────────────────────────────────
function GameModel:explore()
  local ok, err = requireMode(self, "explore")
  if not ok then
    return false, err
  end

  local room = self.dungeon:advance()
  if not room then
    return false, "더 갈 곳이 없습니다"
  end
  self.bus:emit("room_entered", { index = self.dungeon.index, total = #self.dungeon.rooms })

  if room.kind == "enemy" then
    self.enemy = EnemyModel.new(room.enemy)
    self.mode = "battle"
    self.bus:emit("enemy_appeared", { name = self.enemy.name })
  elseif room.kind == "item" then
    local added, reason = self.inventory:add(room.item)
    if added then
      self.bus:emit("item_picked", { name = room.item.name })
    else
      self.bus:emit("item_lost", { name = room.item.name, reason = reason })
    end
  elseif room.kind == "exit" then
    self.mode = "victory"
    self.bus:emit("dungeon_cleared", { gold = self.player.gold })
  end
  return true
end

-- ── 전투 ───────────────────────────────────────────────────────────────────
function GameModel:enemyTurn()
  local enemy, player = self.enemy, self.player
  player:takeDamage(enemy.attack)
  self.bus:emit("enemy_attacked", { name = enemy.name, damage = enemy.attack })
  if player:isDead() then
    self.mode = "gameover"
    self.bus:emit("player_died", { by = enemy.name })
  end
end

function GameModel:attack()
  local ok, err = requireMode(self, "battle")
  if not ok then
    return false, err
  end

  local enemy, player = self.enemy, self.player
  local damage = player:getAttack()
  enemy:takeDamage(damage)
  self.bus:emit("player_attacked", { target = enemy.name, damage = damage })

  if enemy:isDead() then
    player:addGold(enemy.gold)
    self.enemy = nil
    self.mode = "explore"
    self.bus:emit("enemy_killed", { name = enemy.name, gold = enemy.gold })
  else
    self:enemyTurn()
  end
  return true
end

-- 도망치면 적에게 한 번 맞고, 그 방은 지나간다.
function GameModel:flee()
  local ok, err = requireMode(self, "battle")
  if not ok then
    return false, err
  end
  local name = self.enemy.name
  self:enemyTurn()
  if self.mode == "battle" then
    self.enemy = nil
    self.mode = "explore"
    self.bus:emit("fled", { name = name })
  end
  return true
end

-- ── 인벤토리 ───────────────────────────────────────────────────────────────
function GameModel:openInventory()
  if self.mode ~= "explore" and self.mode ~= "battle" then
    return false, "지금은 가방을 열 수 없습니다"
  end
  self.returnMode = self.mode
  self.mode = "inventory"
  return true
end

function GameModel:closeInventory()
  local ok, err = requireMode(self, "inventory")
  if not ok then
    return false, err
  end
  self.mode = self.returnMode
  self.returnMode = nil
  return true
end

-- 아이템 사용 후 이전 모드로 돌아간다. 전투 중이었다면 턴을 소모해 적이 공격한다.
function GameModel:useItem(index)
  local ok, err = requireMode(self, "inventory")
  if not ok then
    return false, err
  end

  local item, reason = self.inventory:take(index)
  if not item then
    return false, reason
  end

  if item.kind == "potion" then
    local healed = self.player:heal(item.power)
    self.bus:emit("item_used", { name = item.name, kind = item.kind, amount = healed })
  elseif item.kind == "weapon" then
    self.player:equip(item)
    self.bus:emit("item_used", { name = item.name, kind = item.kind, amount = item.power })
  end

  self:closeInventory()
  if self.mode == "battle" then
    self:enemyTurn()
  end
  return true
end

-- ── 상점 (문제4: 기존 메서드는 고치지 않고 새 메서드만 추가) ────────────────
-- 생성자에서 구독한 "room_entered" 가 호출한다. explore() 가 방을 옮긴 직후라
-- dungeon.index 는 이미 새 방을 가리킨다. 상점 방이면 shop 모드로 바꾼다.
function GameModel:enterShopIfAny()
  local room = self.dungeon.rooms[self.dungeon.index]
  if not room or room.kind ~= "shop" then
    return
  end
  self.shop = room
  self.mode = "shop"
  self.bus:emit("shop_entered", { name = room.item.name, price = room.price })
end

-- 실패 시 골드·가방은 그대로 두고 false, 이유 를 돌려준다.
function GameModel:buy()
  local ok, err = requireMode(self, "shop")
  if not ok then
    return false, err
  end

  local shop, player = self.shop, self.player
  if player.gold < shop.price then
    return false, string.format("골드가 부족합니다 (필요 %d, 보유 %d)", shop.price, player.gold)
  end
  local added, reason = self.inventory:add(shop.item)
  if not added then
    return false, reason
  end
  player:spendGold(shop.price)
  self.bus:emit("item_bought", { name = shop.item.name, price = shop.price })
  return true
end

function GameModel:leaveShop()
  local ok, err = requireMode(self, "shop")
  if not ok then
    return false, err
  end
  self.shop = nil
  self.mode = "explore"
  self.bus:emit("shop_left", {})
  return true
end

return GameModel
