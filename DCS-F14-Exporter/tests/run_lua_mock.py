"""Run the bundled mock against liblua5.4.so.0 if installed (Linux CI)."""
import ctypes
from pathlib import Path
import os
lib = ctypes.CDLL('liblua5.4.so.0')
lib.luaL_newstate.restype=ctypes.c_void_p
lib.luaL_openlibs.argtypes=[ctypes.c_void_p]
lib.luaL_loadfilex.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p]
lib.luaL_loadfilex.restype=ctypes.c_int
lib.lua_pcallk.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_long,ctypes.c_void_p]
lib.lua_pcallk.restype=ctypes.c_int
lib.lua_tolstring.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p]
lib.lua_tolstring.restype=ctypes.c_char_p
lib.lua_close.argtypes=[ctypes.c_void_p]
root=Path(__file__).resolve().parents[1]
os.chdir(root)
L=lib.luaL_newstate()
try:
    lib.luaL_openlibs(L)
    p=root/'tests/mock_f14.lua'
    code=lib.luaL_loadfilex(L,str(p).encode(),None)
    if code == 0: code=lib.lua_pcallk(L,0,-1,0,0,None)
    if code: raise RuntimeError(lib.lua_tolstring(L,-1,None).decode())
finally:
    lib.lua_close(L)
