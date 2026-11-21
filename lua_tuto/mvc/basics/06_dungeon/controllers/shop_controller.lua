-- shop_controller.lua
-- 상점 모드 입력 담당. 규약: handle(game, input) → ok, err
-- 가격·잔액·가방 검사는 GameModel:buy 가 한다. 여기서는 키만 해석한다.

local ShopController = {}
ShopController.__index = ShopController

function ShopController.new()
  return setmetatable({}, ShopController)
end

function ShopController:handle(game, input)
  if input == "b" then
    return game:buy()
  elseif input == "l" then
    return game:leaveShop()
  end
  return false, "상점에서는 b / l 만 쓸 수 있습니다"
end

return ShopController
