import std.conv;
import std.exception;

import std.stdio;

import erupted;

void enforceVk(VkResult res) {
  enforce(res == VkResult.VK_SUCCESS, res.to!string);
}

void structPrettyPrint(T)(T st) {
  auto fields = __traits(allMembers, typeof(st));
  auto values = st.tupleof;

  ulong maxFieldLength = 0;

  foreach(field; fields) {
    if(field.length > maxFieldLength) maxFieldLength = field.length;
  }

  writef("===== %s =====\n", __traits(identifier, typeof(st)));


  foreach(i, value; values) {
    writef("  | %*s: %s\n", maxFieldLength + 1, fields[i], value);
  }

  writeln("===================\n");
}
