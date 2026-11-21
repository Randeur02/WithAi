-- dungeon_test.lua
-- 예제 6(던전 RPG) 헤드리스 테스트: Model 단위 → Model 간 이벤트 연동 → View 문자열 → Controller 라우팅.
-- 실행: lua lua_tuto/mvc/basics/tests/dungeon_test.lua   (luajit 도 가능)

-- 규칙 검사(전역 변수 금지): 이후 require·실행되는 모든 코드에서
-- 새 전역 변수를 만들거나 정의되지 않은 전역을 읽으면 즉시 오류로 멈춘다.
setmetatable(_G, {
  __newindex = function(_, name)
    error("전역 변수 금지: " .. tostring(name), 2)
  end,
  __index = function(_, name)
    error("정의되지 않은 전역 읽기: " .. tostring(name), 2)
  end,
})

local here = (arg and arg[0] or ""):match("(.*[/\\])") or "./"
local root = here .. "../06_dungeon/"
package.path = root .. "?.lua;" .. package.path

local EventBus = require("models.event_bus")
local QuestModel = require("models.quest_model")
local LogModel = require("models.log_model")
local InventoryModel = require("models.inventory_model")
local PlayerModel = require("models.player_model")
local GameModel = require("models.game_model")

local ScreenView = require("views.screen_view")
local StatusView = require("views.status_view")
local EnemyView = require("views.enemy_view")
local LogView = require("views.log_view")

local InputRouter = require("controllers.input_router")
local ExploreController = require("controllers.explore_controller")
local BattleController = require("controllers.battle_controller")
local InventoryController = require("controllers.inventory_controller")
local EndController = require("controllers.end_controller")

local passed, failed = 0, 0
local function check(name, cond)
  if cond then
    passed = passed + 1
    print("  ok   - " .. name)
  else
    failed = failed + 1
    print("  FAIL - " .. name)
  end
end

local function contains(lines, text)
  for _, line in ipairs(lines or {}) do
    if line:find(text, 1, true) then
      return true
    end
  end
  return false
end

-- 테스트용 작은 던전. 실제 데이터 파일과 독립적이라 기획 수치가 바뀌어도 테스트가 깨지지 않는다.
local function newGame(rooms, player)
  return GameModel.new({
    player = player or { name = "테스터", maxHp = 10, attack = 5 },
    inventoryCapacity = 2,
    logLimit = 3,
    rooms = rooms,
    quests = { { id = "kill", text = "1마리 처치", event = "enemy_killed", needed = 1 } },
  })
end

local WEAK = { kind = "enemy", enemy = { name = "쥐", hp = 5, attack = 1, gold = 2 } }
local TOUGH = { kind = "enemy", enemy = { name = "골렘", hp = 100, attack = 4, gold = 50 } }
local POTION = { kind = "item", item = { name = "물약", kind = "potion", power = 5 } }
local SWORD = { kind = "item", item = { name = "검", kind = "weapon", power = 3 } }
local EXIT = { kind = "exit" }

-- ── 0. 디커플링 ─────────────────────────────────────────────────────────────
print("[0] 디커플링: Model/Controller 에 print·io·love 없음")
local CHECKED_FILES = {
  "models/event_bus.lua", "models/player_model.lua", "models/enemy_model.lua",
  "models/inventory_model.lua", "models/dungeon_model.lua", "models/quest_model.lua",
  "models/log_model.lua", "models/game_model.lua",
  "controllers/explore_controller.lua", "controllers/battle_controller.lua",
  "controllers/inventory_controller.lua", "controllers/end_controller.lua",
  "controllers/input_router.lua",
}
for _, path in ipairs(CHECKED_FILES) do
  local file = assert(io.open(root .. path, "r"), "파일 없음: " .. path)
  local clean = true
  for line in file:lines() do
    local code = line:gsub("%-%-.*$", "")
    if code:find("print%s*%(") or code:find("io%.") or code:find("love%.") then
      clean = false
    end
  end
  file:close()
  check(path, clean)
end

-- ── 1. 작은 Model 들 (단독) ─────────────────────────────────────────────────
print("[1] 작은 Model 단독 테스트")
do
  local bus = EventBus.new()
  local order = {}
  bus:on("ping", function()
    order[#order + 1] = "on"
  end)
  bus:onAny(function(t)
    order[#order + 1] = "any:" .. t
  end)
  bus:emit("ping")
  check("EventBus: onAny 가 먼저, 그다음 on", order[1] == "any:ping" and order[2] == "on")

  local quests = QuestModel.new(bus, { { id = "k", text = "2마리", event = "enemy_killed", needed = 2 } })
  local completed = 0
  bus:on("quest_completed", function()
    completed = completed + 1
  end)
  bus:emit("enemy_killed")
  bus:emit("enemy_killed")
  bus:emit("enemy_killed")
  check("QuestModel: GameModel 없이 이벤트만으로 진행", quests.quests[1].done and quests:countDone() == 1)
  check("QuestModel: 완료 이벤트는 한 번만", completed == 1)

  local log = LogModel.new(EventBus.new(), 2)
  log:push("a", {})
  log:push("b", {})
  log:push("c", {})
  check("LogModel: 최근 N개만 보관, 원본 type 저장", #log.entries == 2 and log.entries[1].type == "b")

  local inv = InventoryModel.new(1)
  check("InventoryModel: 용량 초과 거부", inv:add({ name = "x" }) and inv:add({ name = "y" }) == false)
  check("InventoryModel: 없는 번호 거부", inv:take(5) == nil and inv:take("1") == nil)

  local p = PlayerModel.new({ maxHp = 10, attack = 2 })
  p:takeDamage(4)
  check("PlayerModel: 회복은 최대치까지, 실제 회복량 반환", p:heal(100) == 4 and p.hp == 10)
  p:equip({ name = "검", power = 3 })
  check("PlayerModel: 장비 공격력 합산", p:getAttack() == 5)
end

-- ── 2. GameModel: 여러 Model 이 함께 움직이는 규칙 ──────────────────────────
print("[2] GameModel 통합 규칙")
do
  local g = newGame({ WEAK, EXIT })
  check("시작은 탐험 모드", g.mode == "explore")
  check("탐험 중 공격 불가", g:attack() == false)
  g:explore()
  check("적 방 → 전투 모드 + 적 생성", g.mode == "battle" and g.enemy and g.enemy.name == "쥐")
  check("전투 중 탐험 불가", g:explore() == false)
  g:attack()
  check("처치 → 탐험 복귀, 골드 획득", g.mode == "explore" and g.enemy == nil and g.player.gold == 2)
  check("처치 이벤트가 퀘스트로 전달", g.quests.quests[1].done == true)
  check("로그에 원본 이벤트 기록", g.log.entries[#g.log.entries].type == "quest_completed")
  g:explore()
  check("출구 → 승리", g.mode == "victory" and g:isOver())
end

do
  local g = newGame({ TOUGH })
  g:explore()
  g:attack()
  check("적이 살아 있으면 반격", g.player.hp == 6)
  g:attack()
  g:attack()
  check("체력 0 → 게임 오버", g.mode == "gameover" and g.player.hp == 0)
  check("게임 오버 후 행동 불가", g:attack() == false and g:openInventory() == false)
end

do
  local g = newGame({ TOUGH })
  g:explore()
  g:flee()
  check("도망: 한 대 맞고 탐험 복귀", g.player.hp == 6 and g.mode == "explore" and g.enemy == nil)
end

do
  local g = newGame({ POTION, SWORD, POTION, TOUGH })
  g:explore()
  g:explore()
  g:explore()
  check("가방이 차면 아이템을 두고 옴", #g.inventory.items == 2 and g.log.entries[#g.log.entries].type == "item_lost")
  g:explore()
  g:attack()
  check("전투 중 피해", g.player.hp == 6)
  g:openInventory()
  check("가방 열기 → inventory 모드, 복귀 모드 기억", g.mode == "inventory" and g.returnMode == "battle")
  check("없는 번호 사용 거부", g:useItem(9) == false and g.mode == "inventory")
  g:useItem(1)
  check("전투 중 물약: 회복 후 적의 턴", g.player.hp == 10 - 4 + 4 - 4 and g.mode == "battle")
  g:openInventory()
  g:useItem(1)
  check("검 장착", g.player:getAttack() == 8 and #g.inventory.items == 0)
end

-- ── 3. View: Model 을 읽어 문자열만 만든다 ──────────────────────────────────
print("[3] View")
do
  local g = newGame({ WEAK, EXIT })
  check("EnemyView: 적이 없으면 nil(숨김)", EnemyView.new():lines(g) == nil)
  g:explore()
  check("EnemyView: 전투 중 이름/HP 표시", contains(EnemyView.new():lines(g), "쥐  HP"))
  check("StatusView: 위치 표시", contains(StatusView.new():lines(g), "위치 1/2번 방"))
  check("LogView: 원본 이벤트 → 문장", contains(LogView.new():lines(g), "쥐 이(가) 나타났다!"))

  local hpBefore = g.player.hp
  StatusView.new():lines(g)
  check("View 는 Model 을 바꾸지 않음", g.player.hp == hpBefore and g.mode == "battle")

  local out = {}
  local screen = ScreenView.new(function(s)
    out[#out + 1] = s
  end, { status = StatusView.new(), enemy = EnemyView.new() }, {
    battle = { "status", "enemy" },
    default = { "status" },
  })
  screen:showNotice("알림")
  screen:render(g)
  check("ScreenView: 모드별 레이아웃으로 위젯 합성", contains(out, "-- 상태") and contains(out, "-- 적"))
  check("ScreenView: 알림 표시", contains(out, "! 알림"))
  out = {}
  screen:render(g)
  check("ScreenView: 알림은 한 번만", not contains(out, "! 알림"))
end

-- ── 4. Controller: 모드별 라우팅 ───────────────────────────────────────────
print("[4] Controller 라우팅")
do
  local notices, renders = {}, 0
  local fakeView = {
    showNotice = function(_, msg)
      notices[#notices + 1] = msg
    end,
    render = function()
      renders = renders + 1
    end,
  }
  local endController = EndController.new()
  local g = newGame({ WEAK, EXIT })
  local router = InputRouter.new(g, fakeView, {
    explore = ExploreController.new(),
    battle = BattleController.new(),
    inventory = InventoryController.new(),
    gameover = endController,
    victory = endController,
  })

  check("탐험 모드 a → ExploreController 가 거부", router:handle("a") and #notices == 1)
  router:handle(" n ")
  check("n → 전투 진입 (공백 무시)", g.mode == "battle")
  router:handle("i")
  check("전투 중 i → 가방", g.mode == "inventory")
  router:handle("zz")
  check("가방에서 숫자 아님 → 알림", notices[#notices]:find("번호", 1, true) ~= nil)
  router:handle("b")
  check("b → 전투로 복귀", g.mode == "battle")
  router:handle("a")
  router:handle("n")
  check("승리 모드 도달", g.mode == "victory")
  check("승리 후 아무 입력 → 종료", router:handle("x") == false)
  check("입력마다 render 호출", renders == 7)
  check("q 는 어느 모드에서나 종료", InputRouter.new(newGame({ EXIT }), fakeView, {}):handle("q") == false)
end

-- ── 5. 문제1: 데이터만으로 퀘스트 추가 ─────────────────────────────────────
print("[5] 문제1: 아이템 2번 사용 퀘스트 (데이터만)")
do
  local data = require("data.dungeon_data")
  local def
  for _, q in ipairs(data.quests) do
    if q.event == "item_used" then
      def = q
    end
  end
  check("데이터에 item_used 퀘스트(needed=2) 정의", def ~= nil and def.needed == 2)

  -- 정의가 없어도 아래 검사가 FAIL 로 보이도록 빈 퀘스트로 대체한다.
  local g = GameModel.new({
    player = { name = "테스터", maxHp = 10, attack = 5 },
    inventoryCapacity = 2,
    logLimit = 3,
    rooms = { POTION, POTION, EXIT },
    quests = { def or { id = "none", text = "없음", event = "__none__", needed = 2 } },
  })
  local quest = g.quests.quests[1]
  g:explore()
  g:explore()
  g:openInventory()
  g:useItem(1)
  check("아이템 1번 사용 → 진행 1/2", quest.progress == 1 and not quest.done)
  g:openInventory()
  g:useItem(1)
  check("아이템 2번 사용 → 퀘스트 완료", quest.done == true)
end

-- ── 새 파일용 공통 검사 ─────────────────────────────────────────────────────
-- 아직 없는 모듈도 테스트 전체를 멈추지 않고 FAIL 로 보이게 한다.
local function tryRequire(name)
  local ok, mod = pcall(require, name)
  return ok and mod or nil
end

-- 주석을 뺀 소스. 파일이 없으면 nil.
local function sourceOf(path)
  local file = io.open(root .. path, "r")
  if not file then
    return nil
  end
  local code = {}
  for line in file:lines() do
    code[#code + 1] = (line:gsub("%-%-.*$", ""))
  end
  file:close()
  return table.concat(code, "\n")
end

-- print·io·love 와 추가 금지 문자열(extra)이 없어야 ok. 파일이 없으면 FAIL.
local function checkClean(path, extra)
  local code = sourceOf(path)
  local clean = code ~= nil and not code:find("print%s*%(") and not code:find("io%.") and not code:find("love%.")
  if code then
    for _, text in ipairs(extra or {}) do
      clean = clean and not code:find(text, 1, true)
    end
  end
  local label = "print·io·love" .. (extra and ("·" .. table.concat(extra, "·")) or "")
  check(path .. ": " .. label .. " 없음", clean)
end

-- ── 6. 문제2: 처치 목록 (KillListModel + KillListView) ──────────────────────
print("[6] 문제2: 처치한 적 목록 패널")
do
  local KillListModel = tryRequire("models.kill_list_model")
  local KillListView = tryRequire("views.kill_list_view")
  check("KillListModel 모듈 존재", KillListModel ~= nil)
  check("KillListView 모듈 존재", KillListView ~= nil)
  checkClean("models/kill_list_model.lua", { "models.game_model", "models.player_model" })

  -- Model 단독: GameModel 없이 버스 이벤트만으로 기록
  local names = {}
  if KillListModel then
    local bus = EventBus.new()
    names = KillListModel.new(bus).names
    bus:emit("enemy_killed", { name = "쥐", gold = 2 })
    bus:emit("fled", { name = "골렘" })
    bus:emit("enemy_killed", { name = "박쥐", gold = 1 })
  end
  check("KillListModel: enemy_killed 만 순서대로 기록", #names == 2 and names[1] == "쥐" and names[2] == "박쥐")

  -- GameModel 통합: 처치는 기록, 도망은 제외
  local g = newGame({ WEAK, TOUGH, EXIT })
  local view = KillListView and KillListView.new()
  check("KillListView: 처치 전 빈 목록 안내", view ~= nil and contains(view:lines(g), "아직 없음"))
  g:explore()
  g:attack() -- 쥐 처치
  g:explore()
  g:flee() -- 골렘에게서 도망
  local kills = g.kills
  check("GameModel 이 처치 목록 소유 (game.kills)", kills ~= nil)
  check("처치한 적만 기록, 도망친 적 제외", kills ~= nil and #kills.names == 1 and kills.names[1] == "쥐")
  check("KillListView: 처치한 적 이름 표시", view ~= nil and contains(view:lines(g), "쥐"))
  check("KillListView: 위젯 규약(title)", view ~= nil and type(view.title) == "string")
end

-- ── 7. 문제3: 처치 골드 누적 업적 (Game·PlayerModel 의존 금지) ──────────────
print("[7] 문제3: 처치 골드 누적 업적")
do
  local AchievementModel = tryRequire("models.achievement_model")
  check("AchievementModel 모듈 존재", AchievementModel ~= nil)
  checkClean("models/achievement_model.lua", { "models.game_model", "models.player_model" })

  -- 기준값·문구는 데이터에 있어야 한다 (코드 하드코딩 금지)
  local data = require("data.dungeon_data")
  local def
  for _, a in ipairs(data.achievements or {}) do
    if a.gold == 15 then
      def = a
    end
  end
  check("데이터에 골드 15 업적 정의 (text 포함)", def ~= nil and type(def.text) == "string")

  -- Model 단독: 버스의 enemy_killed 골드만 누적, 기준 도달 시 1회만 발행
  local unlocked = {}
  if AchievementModel then
    local bus = EventBus.new()
    bus:on("achievement_unlocked", function(d)
      unlocked[#unlocked + 1] = d.text
    end)
    AchievementModel.new(bus, { { id = "rich", text = "부자", gold = 15 } })
    bus:emit("enemy_killed", { name = "a", gold = 10 })
    bus:emit("enemy_killed", { name = "b", gold = 4 })
    check("누적 14: 아직 미달성", #unlocked == 0)
    bus:emit("enemy_killed", { name = "c", gold = 1 })
    check("누적 15(경계값): 달성 이벤트 + 데이터 문구 전달", #unlocked == 1 and unlocked[1] == "부자")
    bus:emit("enemy_killed", { name = "d", gold = 20 })
    check("달성 후 추가 처치: 다시 발행하지 않음", #unlocked == 1)
  else
    check("누적 14: 아직 미달성", false)
    check("누적 15(경계값): 달성 이벤트 + 데이터 문구 전달", false)
    check("달성 후 추가 처치: 다시 발행하지 않음", false)
  end

  -- GameModel 통합: 처치 → 업적 → 로그에 문장 1회
  local g = GameModel.new({
    player = { name = "테스터", maxHp = 10, attack = 5 },
    inventoryCapacity = 2,
    logLimit = 5,
    rooms = { WEAK, WEAK, EXIT },
    quests = {},
    achievements = { { id = "rich", text = "쥐 사냥꾼", gold = 4 } },
  })
  g:explore()
  g:attack()
  local function countUnlocked()
    local n = 0
    for _, e in ipairs(g.log.entries) do
      if e.type == "achievement_unlocked" then
        n = n + 1
      end
    end
    return n
  end
  check("골드 2: 로그에 업적 없음", countUnlocked() == 0)
  g:explore()
  g:attack()
  check("골드 4: 로그에 업적 1회 기록", countUnlocked() == 1)
  check("LogView: 업적 문장에 데이터 문구 표시", contains(LogView.new():lines(g), "업적 달성: 쥐 사냥꾼"))
end

-- ── 8. 문제4: 상점 방 + ShopController ─────────────────────────────────────
print("[8] 문제4: 상점 방 + ShopController")
local SHOP = { kind = "shop", item = { name = "물약", kind = "potion", power = 5 }, price = 5 }
local ShopController = tryRequire("controllers.shop_controller")
local ShopView = tryRequire("views.shop_view")
do
  local CommandView = require("views.command_view")
  check("ShopController 모듈 존재", ShopController ~= nil)
  check("ShopView 모듈 존재", ShopView ~= nil)
  checkClean("controllers/shop_controller.lua")

  -- 실제 데이터: 출구 직전 상점(물약 5골드), 탐험 퀘스트 = 방 수
  local data = require("data.dungeon_data")
  local rooms = data.rooms
  local shopRoom = rooms[#rooms - 1]
  check(
    "데이터: 출구 직전 방이 상점(물약, 5골드)",
    rooms[#rooms].kind == "exit"
      and shopRoom.kind == "shop"
      and shopRoom.price == 5
      and shopRoom.item ~= nil
      and shopRoom.item.kind == "potion"
  )
  local explorer
  for _, q in ipairs(data.quests) do
    if q.id == "explorer" then
      explorer = q
    end
  end
  check("데이터: 탐험 퀘스트 needed 가 방 수와 일치", explorer ~= nil and explorer.needed == #rooms)

  local p = PlayerModel.new({ maxHp = 10, attack = 1 })
  p:addGold(7)
  if p.spendGold then
    p:spendGold(5)
  end
  check("PlayerModel:spendGold 골드 차감 (새 메서드)", p.gold == 2)

  local g = newGame({ SHOP, EXIT }) -- 가방 용량 2
  local function buy()
    if g.buy then
      return g:buy()
    end
    return nil, ""
  end
  g:explore()
  check("상점 방 진입 → shop 모드", g.mode == "shop")
  check("상점에서 탐험·공격 불가", g:explore() == false and g:attack() == false)

  local ok, reason = buy()
  check("골드 부족 → 실패 + 이유", ok == false and reason:find("골드가 부족", 1, true) ~= nil)
  check("골드 부족 실패 시 골드·가방 그대로", g.player.gold == 0 and #g.inventory.items == 0)

  g.player:addGold(12)
  buy()
  check("구매 성공 → 골드 -5, 가방 +1", g.player.gold == 7 and #g.inventory.items == 1 and g.inventory.items[1].name == "물약")
  check("구매 기록이 로그에", g.log.entries[#g.log.entries].type == "item_bought")
  buy() -- 골드 2, 가방 2/2
  g.player:addGold(10) -- 골드 12
  ok, reason = buy()
  check("가방 가득 → 실패 + 이유", ok == false and reason:find("가득", 1, true) ~= nil)
  check("가방 가득 실패 시 골드·가방 그대로", g.player.gold == 12 and #g.inventory.items == 2)

  local shopLines = ShopView and ShopView.new():lines(g)
  check("ShopView: 상품·가격을 데이터에서 표시", contains(shopLines, "물약") and contains(shopLines, "5골드"))
  local commandLines = CommandView.new():lines(g)
  check("CommandView: 상점 조작 안내", contains(commandLines, "구매") and contains(commandLines, "나가기"))

  local left = g.leaveShop and g:leaveShop()
  check("나가기 → 탐험 복귀", left == true and g.mode == "explore")
  check("나간 뒤 ShopView 숨김(nil)", ShopView ~= nil and ShopView.new():lines(g) == nil)
  g:explore()
  check("상점 다음 출구 → 승리", g.mode == "victory")
end

-- 라우터 경유: b / l 키 해석과 실패 이유 알림
do
  local notices = {}
  local fakeView = {
    showNotice = function(_, msg)
      notices[#notices + 1] = msg
    end,
    render = function() end,
  }
  local g = newGame({ SHOP, EXIT })
  local router = InputRouter.new(g, fakeView, {
    explore = ExploreController.new(),
    shop = ShopController and ShopController.new(),
  })
  router:handle("n")
  local wasShop = g.mode == "shop"
  router:handle("x")
  check("상점에서 다른 키 → 안내 알림", (notices[#notices] or ""):find("b / l", 1, true) ~= nil)
  router:handle("b")
  check("b 실패 → 골드 부족 이유 알림", (notices[#notices] or ""):find("골드가 부족", 1, true) ~= nil)
  router:handle("l")
  check("shop 모드에서 l → 탐험 복귀", wasShop and g.mode == "explore")
end

print(string.format("\n결과: %d 통과, %d 실패", passed, failed))
if failed > 0 then
  os.exit(1)
end
