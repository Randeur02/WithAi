-- shop_view.lua
-- 상점 패널. 상품·가격은 데이터(상점 방)에서 읽으므로 가격을 바꿔도 이 파일은 그대로다.
-- 읽는 모델: shop (상점 방 데이터), player.gold. 상점 밖에서는 nil(숨김).

local KIND_TEXT = { potion = "회복", weapon = "공격" }

local ShopView = { title = "상점" }
ShopView.__index = ShopView

function ShopView.new()
  return setmetatable({}, ShopView)
end

function ShopView:lines(game)
  local shop = game.shop
  if not shop then
    return nil
  end
  local item = shop.item
  return {
    string.format("%s (%s +%d) — %d골드", item.name, KIND_TEXT[item.kind] or item.kind, item.power, shop.price),
    string.format("보유 골드 %d", game.player.gold),
  }
end

return ShopView
