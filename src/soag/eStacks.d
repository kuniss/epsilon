module soag.eStacks;

import runtime;
import ALists = soag.eALists;

struct Stack
{
    ALists.AListDesc aList;
}

void New(ref Stack S, int Len)
{
    S = Stack();
    ALists.New(S.aList, Len);
}

///
unittest
{
    Stack stack;

    New(stack, 0);
    assert(IsEmpty(stack));
}

void Reset(ref Stack S)
{
    ALists.Reset(S.aList);
}

///
unittest
{
    Stack stack;

    New(stack, 0);
    Push(stack, 3);
    Reset(stack);
    assert(IsEmpty(stack));
}

void Push(ref Stack S, int Val)
{
    ALists.Append(S.aList, Val);
}

///
unittest
{
    Stack stack;

    New(stack, 0);
    Push(stack, 3);
    assert(!IsEmpty(stack));
    assert(Top(stack) == 3);
}

void Pop(ref Stack S, ref int Val)
in (!IsEmpty(S))
{
    Val = S.aList.Elem[S.aList.Last];
    ALists.Delete(S.aList, S.aList.Last);
}

///
unittest
{
    Stack stack;
    int value;

    New(stack, 0);
    Push(stack, 3);
    Pop(stack, value);
    assert(value == 3);
    assert(IsEmpty(stack));
}

int Top(ref Stack S)
in (!IsEmpty(S))
{
    return S.aList.Elem[S.aList.Last];
}

bool IsEmpty(Stack S)
{
    return S.aList.Last < ALists.firstIndex;
}
