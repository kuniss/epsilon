module $;

import IO = eIO;
import io : Position;
import runtime;
import Stacks = soag.eLIStacks;
import std.stdio;

const nil = -1;
const initialStorageSize = 128;
const syntacticPart = 0;
const hyperArityConst = $;
$
alias TreeType = long;
alias OpenTree = TreeType[];
alias OpenPos = Position[];
// alias HeapType = long;
alias IndexType = long;

OpenTree Tree;
OpenPos PosTree;
long ErrorCounter;
int AffixVarCount;
Position Pos;
IO.TextOut Out;
HeapType RefIncVar;

class SemTreeEntry
{
    long Rule;
    Position Pos;
    IndexType Adr;
    IndexType VarInd;
}

alias OpenSemTree = SemTreeEntry[];
alias OpenVar = HeapType[];
alias OpenAffPos = HeapType[];

OpenSemTree SemTree;
OpenVar Var;
OpenAffPos AffPos;
IndexType NextSemTree;
IndexType NextVar;

// insert evaluator global things
$
void ExpandSemTree()
{
    OpenSemTree SemTree1 = new SemTreeEntry[2 * SemTree.length];

    for (IndexType i = 0; i < SemTree.length; ++i)
        SemTree1[i] = SemTree[i];
    SemTree = SemTree1;
}

void ExpandVar()
{
    OpenVar Var1 = new HeapType[2 * Var.length];

    for (IndexType i = 0; i < Var.length; ++i)
        Var1[i] = Var[i];
    Var = Var1;
}

// Predicates

$

void Init()
{
    SemTree = new SemTreeEntry[initialStorageSize];
    AffPos = new HeapType[$];
    Var = new HeapType[8 * initialStorageSize];
    NextSemTree = 0;
    NextVar = 0;
    AffixVarCount = 0;
    $
}

void TraverseSyntaxTree(OpenTree Tree1, OpenPos PosTree1, long ErrCounter, TreeType Adr, int HyperArity)
{
    IndexType StartSymbol;
    HeapType V1;

    if (HyperArity != hyperArityConst)
    {
        throw new Exception("internal error: 'arityConst' is wrong");
    }
    Tree = Tree1;
    PosTree = PosTree1;
    ErrorCounter = ErrCounter;
    Init;
    StartSymbol = NextSemTree;
    SemTree[StartSymbol] = new SemTreeEntry;
    SemTree[StartSymbol].Adr = Adr;
    SemTree[StartSymbol].Rule = MOD($Tree[Adr], hyperArityConst);
    ++NextSemTree;
    Visit(StartSymbol, syntacticPart);
    Visit(StartSymbol, 1);
    V1 = AffPos[$];
    if (ErrorCounter > 0)
    {
        IO.Msg.write("  ");
        IO.Msg.write(ErrorCounter);
        IO.Msg.write(" errors detected\n");
        IO.Msg.flush;
    }
    else
    {
        $
    }
    $
    if (IO.IsOption('i'))
    {
        IO.Msg.write("\tsemantic tree of ");
        IO.Msg.write(AffixVarCount);
        IO.Msg.write(" affixes uses ");
        IO.Msg.write(NextVar);
        IO.Msg.write(" affix variables, with\n\t\t");
        IO.Msg.write($);
        IO.Msg.write(" stacks and\n\t\t");
        IO.Msg.write($);
        IO.Msg.write(" global variables\n");
    }
    Tree = null;
    PosTree = null;
    SemTree = null;
    Var = null;
    AffPos = null;
}

// END $.
$
