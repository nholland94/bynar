import std.algorithm.iteration;
import std.conv;
import std.exception;
import std.range;
import std.typecons;

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

void push(T)(ref T[] array, T el) {
  ulong i = array.length++;
  array[i] = el;
}

bool arrayEqual(Range)(Range a, Range b) {
  if(a.length != b.length) return false;
  foreach(i; iota(a.length)) if(a[i] != b[i]) return false;
  return true;
}

size_t alignSize(size_t size, size_t alignment) {
  size_t remainder = size % alignment;
  return remainder == 0 ? size : size + alignment - remainder;
}

unittest {
  assert(alignSize(0x20, 0x20) == 0x20);
  assert(alignSize(0xa0, 0x20) == 0xa0);
  assert(alignSize(0xd2, 0x20) == 0xe0);
  assert(alignSize(0x36, 0x50) == 0x50);
}

template destruct(A...) {
  void destruct(B)(B b) @property {
    foreach(I, ref a; A) {
      static if(!is(typeof(A[I]):typeof(null)))
        a = b[I];
    }
  }
}

unittest {
  Tuple!(int, int) ta() { return tuple!(int, int)(1, 2); }
  Tuple!(float, int) tb() { return tuple!(float, int)(1.5, 3); }

  int a, b;
  destruct!(a, b) = ta();
  assert(a == 1);
  assert(b == 2);

  float c;
  int d;
  destruct!(c, d) = tb();
  assert(c == 1.5);
  assert(d == 3);

  float e;
  int f;
  uint g;
  destruct!(e, f, g) = tuple!(float, int, uint)(1.0, 4, 15u);
  assert(e == 1.0);
  assert(f == 4);
  assert(g == 15u);
}

Range flatten(Range)(Range[] nestedArray) {
  Range newArray;

  ulong len = 0;
  foreach(arr; nestedArray) len += arr.length;
  newArray.length = len;

  ulong index = 0;
  foreach(arr; nestedArray) {
    foreach(el; arr) {
      newArray[index++] = el;
    }
  }

  return newArray;
}

unittest {
  assert(flatten([[1, 2], [3, 4]]) == [1, 2, 3, 4]);
  assert(flatten([[1], [2, 3], [4, 5, 6]]) == [1, 2, 3, 4, 5, 6]);
}
