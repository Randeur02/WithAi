#!/bin/sh
# 전역 변수 가드를 걸고 자동 시연 실행. lua.exe 가 직접 넣는 arg 만 허용.
# 사용: sh quiz_logs/strict_demo.sh <lua 실행기 경로>
LUA="${1:-lua}"
HERE="$(dirname "$0")"
"$LUA" -e 'setmetatable(_G,{__newindex=function(t,n,v) if n=="arg" then rawset(t,n,v) else error("전역 변수 금지: "..tostring(n),2) end end})' "$HERE/../06_dungeon/main.lua"
