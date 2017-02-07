enum IntRelOp {
  Input = 0,
  Difference = 1,
  Ratio = 2
}

struct IntRelExp {
  int* bytecode;

  T evaluate(T)(T input) {
    return this.evalRec(input, bytecode);
  }

  private T evalRec(T)(T input, int* code) {
    switch(*code) {
    case IntRelOp.Input:
      return input;
    case IntRelOp.Difference:
      int arg = *(++code);

      return evalRec(input, ++code) - arg;
    case IntRelOp.Ratio:
      int numerator = *(++code);
      int denominator = *(++code);

      return evalRec(input, ++code) * numerator / denominator;
    default:
      throw new Exception("Invalid int rel exp bytcode");
    }
  }
}

