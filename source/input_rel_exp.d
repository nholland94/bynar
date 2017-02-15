enum InputRelOp {
  Input = 0,
  Difference = 1,
  Ratio = 2
}

struct InputRelExp {
  int* bytecode;

  T evaluate(T)(T input) {
    return this.evalRec(input, bytecode);
  }

  private T evalRec(T)(T input, int* code) {
    switch(*code) {
    case InputRelOp.Input:
      return input;
    case InputRelOp.Difference:
      int arg = *(++code);

      return evalRec(input, ++code) - arg;
    case InputRelOp.Ratio:
      int numerator = *(++code);
      int denominator = *(++code);

      return evalRec(input, ++code) * numerator / denominator;
    default:
      throw new Exception("Invalid int rel exp bytcode");
    }
  }
}

/*
import std.variant;

struct Input {};
struct Constant(T) { T value; };
struct DifferenceT(Self) { Self left; Self right; };
struct RatioT(Self) { Self left; Self right; };

alias InputRelExp(T) = Algebraic!(Input, Constant!T, DifferenceT!(This*), RatioT!(This*));
alias Difference(T) = DifferenceT!(InputRelExp!T);
alias Ratio(T) = RatioT!(InputRelExp!T);

T evaluateInputRelExp(T)(T input, InputRelExp!T exp) {
  return exp.tryVisit!(
    (Input i)        => input,
    (Constant!T c)   => c.value,
    (Difference!T d) => evaluateInputRelExp!T(input, d.left) - evaluateInputRelExp!T(input, d.right),
    (Ratio!T r)      => evaluateInputRelExp!T(input, r.left) / evaluateInputRelExp!T(input, r.right)
  )();
}

unittest {
  // TODO more tests
  Constant!int c = Constant!int(2);
  Input i = Input();
  InputRelExp!int doubleExp = Ratio!int(&c, &i); 

  assert(evaluateInputRelExp(5, doubleExp) == 10);
  assert(evaluateInputRelExp(-50, doubleExp) == -100);
}
*/
