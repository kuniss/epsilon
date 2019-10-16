module eSSweep;
import runtime;
import Sets = eSets;
import IO = eIO;
import EAG = eEAG;
import EmitGen = eEmitGen;
import EvalGen = eSLEAGGen;

const nil = 0;
const indexOfFirstAlt = 1;
int[] FactorOffset;
Sets.OpenSet GenNonts;
Sets.OpenSet GenFactors;
bool Error;
bool ShowMod;
bool Compiled;
void Init()
{
    NEW(FactorOffset, EAG.NextHFactor + EAG.NextHAlt + 1);
    Sets.New(GenFactors, EAG.NextHNont);
    Sets.Intersection(GenFactors, EAG.Prod, EAG.Reach);
    Sets.New(GenNonts, EAG.NextHNont);
    Sets.Difference(GenNonts, GenFactors, EAG.Pred);
    Error = false;
    ShowMod = IO.IsOption("m");
}

void Finit()
{
    FactorOffset = null;
}

void GenerateMod(bool CreateMod)
{
    const firstEdge = 1;
    const firstStack = 0;
    class EdgeRecord
    {
        int Dest;
        int Next;
    }

    alias OpenEdge = EdgeRecord[];
    class FactorRecord
    {
        int Vars;
        int CountAppl;
        int Prio;
        EAG.Factor F;
    }

    class VarRecord
    {
        int Factors;
    }

    int N;
    int V;
    IO.TextOut Mod;
    IO.TextIn Fix;
    char[EAG.BaseNameLen + 10] Name;
    bool OpenError;
    bool CompileError;
    EAG.Rule SavedNontDef;
    int SavedNextHFactor;
    int SavedNextHAlt;
    FactorRecord[] Factor;
    VarRecord[] Var;
    OpenEdge Edge;
    int NextEdge;
    int[] Stack;
    int NextStack;
    Sets.OpenSet DefVars;
    void Expand()
    {
        OpenEdge Edge1;
        long i;
        if (NextEdge >= Edge.length)
        {
            NEW(Edge1, 2 * Edge.length);
            for (i = firstEdge; i <= Edge.length - 1; ++i)
            {
                Edge1[i] = Edge[i];
            }
            Edge = Edge1;
        }
    }

    void InclFix(char Term)
    {
        char c;
        IO.Read(Fix, c);
        while (c != Term)
        {
            if (c == '\x00')
            {
                IO.WriteText(IO.Msg, "\n  error: unexpected end of eSSweep.Fix\n");
                IO.Update(IO.Msg);
                HALT(99);
            }
            IO.Write(Mod, c);
            IO.Read(Fix, c);
        }
    }

    void Append(ref char[] Dest, char[] Src, char[] Suf)
    {
        int i;
        int j;
        i = 0;
        j = 0;
        while (Src[i] != '\x00' && i < Dest.length - 1)
        {
            Dest[i] = Src[i];
            ++i;
        }
        while (Suf[j] != '\x00' && i < Dest.length - 1)
        {
            Dest[i] = Suf[j];
            ++i;
            ++j;
        }
        Dest[i] = '\x00';
    }

    int HyperArity()
    {
        int N;
        int i;
        int Max;
        EAG.Alt A;
        Sets.OpenSet Nonts;
        Sets.New(Nonts, EAG.NextHNont);
        Sets.Difference(Nonts, EAG.All, EAG.Pred);
        Max = 0;
        for (N = EAG.firstHNont; N <= EAG.NextHNont - 1; ++N)
        {
            if (Sets.In(Nonts, N))
            {
                A = EAG.HNont[N].Def.Sub;
                i = 0;
                do
                {
                    ++i;
                    A = A.Next;
                }
                while (!(A == null));
                if (EAG.HNont[N].Def is EAG.Opt || EAG.HNont[N].Def is EAG.Rep)
                {
                    ++i;
                }
                if (i > Max)
                {
                    Max = i;
                }
            }
        }
        i = 1;
        while (i <= Max)
        {
            i = i * 2;
        }
        return i;
    }

    void SaveAndPatchNont(int N)
    {
        EAG.Grp Def;
        EAG.Alt A;
        EAG.Alt A1;
        EAG.Alt A2;
        EAG.Factor F;
        EAG.Nont F1;
        EAG.Nont F2;
        SavedNontDef = EAG.HNont[N].Def;
        SavedNextHFactor = EAG.NextHFactor;
        SavedNextHAlt = EAG.NextHAlt;
        NEW(Def);
        A = EAG.HNont[N].Def.Sub;
        A2 = null;
        do
        {
            NEW(A1);
            A1 = A;
            A1.Sub = null;
            A1.Last = null;
            A1.Next = null;
            if (A2 != null)
            {
                A2.Next = A1;
            }
            else
            {
                Def.Sub = A1;
            }
            A2 = A1;
            F = A.Sub;
            F2 = null;
            while (F != null)
            {
                if (F is EAG.Nont && Sets.In(GenFactors, F(EAG.Nont).Sym))
                {
                    NEW(F1);
                    F1 = F(EAG.Nont);
                    F1.Prev = F2;
                    F1.Next = null;
                    A1.Last = F1;
                    if (F2 != null)
                    {
                        F2.Next = F1;
                    }
                    else
                    {
                        A1.Sub = F1;
                    }
                    F2 = F1;
                }
                F = F.Next;
            }
            if (EAG.HNont[N].Def is EAG.Rep)
            {
                NEW(F1);
                F1.Ind = EAG.NextHFactor;
                ++EAG.NextHFactor;
                F1.Prev = A1.Last;
                A1.Last = F1;
                if (A1.Sub == null)
                {
                    A1.Sub = F1;
                }
                if (F1.Prev != null)
                {
                    F1.Prev.Next = F1;
                }
                F1.Next = null;
                F1.Sym = N;
                F1.Pos = A1.Actual.Pos;
                F1.Actual = A1.Actual;
                A1.Actual.Pos = IO.UndefPos;
                A1.Actual.Params = EAG.empty;
            }
            A = A.Next;
        }
        while (!(A == null));
        if (EAG.HNont[N].Def is EAG.Opt || EAG.HNont[N].Def is EAG.Rep)
        {
            NEW(A1);
            A1.Ind = EAG.NextHAlt;
            ++EAG.NextHAlt;
            A1.Up = N;
            A1.Next = null;
            A1.Sub = null;
            A1.Last = null;
            if (EAG.HNont[N].Def is EAG.Opt)
            {
                A1.Scope = EAG.HNont[N].Def(EAG.Opt).Scope;
                A1.Formal = EAG.HNont[N].Def(EAG.Opt).Formal;
                A1.Pos = EAG.HNont[N].Def(EAG.Opt).EmptyAltPos;
            }
            else
            {
                A1.Scope = EAG.HNont[N].Def(EAG.Rep).Scope;
                A1.Formal = EAG.HNont[N].Def(EAG.Rep).Formal;
                A1.Pos = EAG.HNont[N].Def(EAG.Rep).EmptyAltPos;
            }
            A1.Actual.Params = EAG.empty;
            A1.Actual.Pos = IO.UndefPos;
            A2.Next = A1;
        }
        EAG.HNont[N].Def = Def;
    }

    void RestoreNont(int N)
    {
        EAG.HNont[N].Def = SavedNontDef;
        EAG.NextHFactor = SavedNextHFactor;
        EAG.NextHAlt = SavedNextHAlt;
    }

    void ComputePermutation(int N)
    {
        const def = 0;
        const right = 1;
        const appl = 2;
        EAG.Alt A;
        EAG.Factor F;
        EAG.Factor F1;
        int Prio;
        int Index;
        int Offset;
        int NE;
        int VE;
        int V;
        void TravParams(int op, int P, EAG.Factor F)
        {
            bool Def;
            void NewEdge(ref int From, int To)
            {
                if (NextEdge >= Edge.length)
                {
                    Expand;
                }
                Edge[NextEdge].Dest = To;
                Edge[NextEdge].Next = From;
                From = NextEdge;
                ++NextEdge;
            }

            void Tree(int Node)
            {
                int n;
                if (Node < 0)
                {
                    switch (op)
                    {
                    case def:
                        if (Def)
                        {
                            Sets.Incl(DefVars, -Node);
                        }
                        break;
                    case right:
                        if (!Sets.In(DefVars, -Node))
                        {
                            if (Def)
                            {
                                NewEdge(Factor[F.Ind].Vars, -Node);
                            }
                            else
                            {
                                NewEdge(Var[-Node].Factors, F.Ind);
                                ++Factor[F.Ind].CountAppl;
                            }
                        }
                        break;
                    case appl:
                        if (!Def && !Sets.In(DefVars, -Node))
                        {
                            IO.WriteText(IO.Msg, "\n  ");
                            IO.WritePos(IO.Msg, EAG.ParamBuf[P].Pos);
                            IO.WriteText(IO.Msg, "  variable '");
                            EAG.WriteVar(IO.Msg, -Node);
                            IO.WriteText(IO.Msg, " is not defined");
                            IO.Update(IO.Msg);
                            Error = true;
                        }
                        break;
                    }
                }
                else
                {
                    for (n = 1; n <= EAG.MAlt[EAG.NodeBuf[Node]].Arity; ++n)
                    {
                        Tree(EAG.NodeBuf[Node + n]);
                    }
                }
            }

            while (EAG.ParamBuf[P].Affixform != EAG.nil)
            {
                Def = EAG.ParamBuf[P].isDef;
                Tree(EAG.ParamBuf[P].Affixform);
                ++P;
            }
        }

        void Pop(ref EAG.Factor F)
        {
            int i;
            int MinPrio;
            int MinIndex;
            MinPrio = int.max;
            for (i = firstStack; i <= NextStack - 1; ++i)
            {
                if (Factor[Stack[i]].Prio < MinPrio)
                {
                    MinPrio = Factor[Stack[i]].Prio;
                    MinIndex = i;
                }
            }
            F = Factor[Stack[MinIndex]].F;
            Stack[MinIndex] = Stack[NextStack - 1];
            --NextStack;
        }

        A = EAG.HNont[N].Def.Sub;
        do
        {
            Sets.Empty(DefVars);
            NextEdge = firstEdge;
            NextStack = firstStack;
            TravParams(def, A.Formal.Params, null);
            F = A.Sub;
            Prio = 0;
            Offset = 1;
            while (F != null)
            {
                Factor[F.Ind].Vars = nil;
                Factor[F.Ind].CountAppl = 0;
                Factor[F.Ind].Prio = Prio;
                ++Prio;
                Factor[F.Ind].F = F;
                if (!Sets.In(EAG.Pred, F(EAG.Nont).Sym))
                {
                    FactorOffset[F.Ind] = Offset;
                    ++Offset;
                }
                TravParams(right, F(EAG.Nont).Actual.Params, F);
                if (Factor[F.Ind].CountAppl == 0)
                {
                    Stack[NextStack] = F.Ind;
                    ++NextStack;
                }
                F = F.Next;
            }
            A.Sub = null;
            A.Last = null;
            F1 = null;
            Index = 0;
            while (NextStack > firstStack)
            {
                Pop(F);
                F.Prev = F1;
                F.Next = null;
                A.Last = F;
                if (F1 != null)
                {
                    F1.Next = F;
                }
                else
                {
                    A.Sub = F;
                }
                F1 = F;
                ++Index;
                VE = Factor[F.Ind].Vars;
                while (VE != nil)
                {
                    V = Edge[VE].Dest;
                    if (!Sets.In(DefVars, V))
                    {
                        NE = Var[V].Factors;
                        while (NE != nil)
                        {
                            --Factor[Edge[NE].Dest].CountAppl;
                            if (Factor[Edge[NE].Dest].CountAppl == 0)
                            {
                                Stack[NextStack] = Edge[NE].Dest;
                                ++NextStack;
                            }
                            NE = Edge[NE].Next;
                        }
                        Sets.Incl(DefVars, V);
                    }
                    VE = Edge[VE].Next;
                }
            }
            if (Index == Prio)
            {
                TravParams(appl, A.Formal.Params, null);
            }
            else
            {
                IO.WriteText(IO.Msg, "\n  ");
                IO.WritePos(IO.Msg, A.Pos);
                IO.WriteText(IO.Msg, "  alternative is not single sweep");
                IO.Update(IO.Msg);
                Error = true;
            }
            A = A.Next;
        }
        while (!(A == null));
    }

    void GenerateNont(int N)
    {
        EAG.Alt A;
        EAG.Factor F;
        EAG.Factor F1;
        int AltIndex;
        EvalGen.ComputeVarNames(N, false);
        IO.WriteText(Mod, "PROCEDURE P");
        IO.WriteInt(Mod, N);
        IO.WriteText(Mod, "(Adr : TreeType");
        EvalGen.GenFormalParams(N, false);
        IO.WriteText(Mod, ");");
        IO.WriteText(Mod, "   (* ");
        EAG.WriteHNont(Mod, N);
        if (EAG.HNont[N].Id < 0)
        {
            IO.WriteText(Mod, " in ");
            EAG.WriteNamedHNont(Mod, N);
        }
        IO.WriteText(Mod, " *)\n");
        EvalGen.GenVarDecl(N);
        IO.WriteText(Mod, "BEGIN\n");
        IO.WriteText(Mod, "\tCASE Tree[Adr] MOD hyperArityConst OF\n");
        A = EAG.HNont[N].Def.Sub;
        AltIndex = indexOfFirstAlt;
        do
        {
            IO.WriteText(Mod, "\t\t| ");
            IO.WriteInt(Mod, AltIndex);
            IO.WriteText(Mod, " : \n");
            EvalGen.InitScope(A.Scope);
            if (EvalGen.PosNeeded(A.Formal.Params))
            {
                IO.WriteText(Mod, "Pos := PosTree[Adr];\n");
            }
            EvalGen.GenAnalPred(N, A.Formal.Params);
            F = A.Sub;
            while (F != null)
            {
                if (!Sets.In(EAG.Pred, F(EAG.Nont).Sym))
                {
                    EvalGen.GenSynPred(N, F(EAG.Nont).Actual.Params);
                    IO.WriteText(Mod, "\t\tP");
                    IO.WriteInt(Mod, F(EAG.Nont).Sym);
                    IO.WriteText(Mod, "(Tree[Adr + ");
                    IO.WriteInt(Mod, FactorOffset[F.Ind]);
                    IO.WriteText(Mod, "]");
                    EvalGen.GenActualParams(F(EAG.Nont).Actual.Params, false);
                    IO.WriteText(Mod, ");   (* ");
                    EAG.WriteHNont(Mod, F(EAG.Nont).Sym);
                    if (EAG.HNont[F(EAG.Nont).Sym].Id < 0)
                    {
                        IO.WriteText(Mod, " in ");
                        EAG.WriteNamedHNont(Mod, F(EAG.Nont).Sym);
                    }
                    IO.WriteText(Mod, " *)\n");
                    if (EvalGen.PosNeeded(F(EAG.Nont).Actual.Params))
                    {
                        IO.WriteText(Mod, "Pos := PosTree[Adr + ");
                        IO.WriteInt(Mod, FactorOffset[F.Ind]);
                        IO.WriteText(Mod, "];\n");
                    }
                    EvalGen.GenAnalPred(N, F(EAG.Nont).Actual.Params);
                }
                else
                {
                    EvalGen.GenSynPred(N, F(EAG.Nont).Actual.Params);
                    IO.WriteText(Mod, "Pos := PosTree[Adr + ");
                    F1 = F.Prev;
                    while (F1 != null && Sets.In(EAG.Pred, F1(EAG.Nont).Sym))
                    {
                        F1 = F1.Prev;
                    }
                    if (F1 == null)
                    {
                        IO.WriteInt(Mod, 0);
                    }
                    else
                    {
                        IO.WriteInt(Mod, FactorOffset[F1.Ind]);
                    }
                    IO.WriteText(Mod, "];\n");
                    EvalGen.GenPredCall(F(EAG.Nont).Sym, F(EAG.Nont).Actual.Params);
                    EvalGen.GenAnalPred(N, F(EAG.Nont).Actual.Params);
                }
                F = F.Next;
            }
            EvalGen.GenSynPred(N, A.Formal.Params);
            A = A.Next;
            ++AltIndex;
        }
        while (!(A == null));
        IO.WriteText(Mod, "\tEND;\n");
        IO.WriteText(Mod, "END P");
        IO.WriteInt(Mod, N);
        IO.WriteText(Mod, ";\n\n");
    }

    EvalGen.InitTest;
    Error = Error || !EvalGen.PredsOK();
    if (CreateMod)
    {
        IO.OpenIn(Fix, "eSSweep.Fix", OpenError);
        if (OpenError)
        {
            IO.WriteText(IO.Msg, "\n  error: could not open eSSweep.Fix\n");
            IO.Update(IO.Msg);
            HALT(99);
        }
        Append(Name, EAG.BaseName, "Eval");
        IO.CreateModOut(Mod, Name);
        if (!Error)
        {
            EvalGen.InitGen(Mod, EvalGen.sSweepPass);
            InclFix("$");
            IO.WriteText(Mod, Name);
            InclFix("$");
            IO.WriteInt(Mod, HyperArity());
            InclFix("$");
            EvalGen.GenDeclarations;
            for (N = EAG.firstHNont; N <= EAG.NextHNont - 1; ++N)
            {
                if (Sets.In(GenNonts, N))
                {
                    IO.WriteText(Mod, "PROCEDURE^ P");
                    IO.WriteInt(Mod, N);
                    IO.WriteText(Mod, "(Adr : TreeType");
                    EvalGen.GenFormalParams(N, false);
                    IO.WriteText(Mod, ");");
                    IO.WriteText(Mod, "   (* ");
                    EAG.WriteHNont(Mod, N);
                    if (EAG.HNont[N].Id < 0)
                    {
                        IO.WriteText(Mod, " in ");
                        EAG.WriteNamedHNont(Mod, N);
                    }
                    IO.WriteText(Mod, " *)\n");
                }
            }
            EvalGen.GenPredProcs;
            IO.WriteLn(Mod);
        }
    }
    NEW(Factor, EAG.NextHFactor + EAG.NextHAlt + 1);
    NEW(Var, EAG.NextVar + 1);
    NEW(Edge, 127);
    NEW(Stack, EAG.NextHFactor + 1);
    Sets.New(DefVars, EAG.NextVar);
    for (V = EAG.firstVar; V <= EAG.NextVar - 1; ++V)
    {
        Var[V].Factors = nil;
    }
    for (N = EAG.firstHNont; N <= EAG.NextHNont - 1; ++N)
    {
        if (Sets.In(GenNonts, N))
        {
            SaveAndPatchNont(N);
            ComputePermutation(N);
            if (!Error)
            {
                Error = !EvalGen.IsLEAG(N, true);
                if (!Error && CreateMod)
                {
                    GenerateNont(N);
                }
            }
            RestoreNont(N);
        }
    }
    if (CreateMod)
    {
        if (!Error)
        {
            EmitGen.GenEmitProc(Mod);
            InclFix("$");
            IO.WriteText(Mod, "P");
            IO.WriteInt(Mod, EAG.StartSym);
            InclFix("$");
            EmitGen.GenEmitCall(Mod);
            InclFix("$");
            EmitGen.GenShowHeap(Mod);
            InclFix("$");
            IO.WriteText(Mod, EAG.BaseName);
            IO.WriteText(Mod, "Eval");
            InclFix("$");
            IO.Update(Mod);
            if (ShowMod)
            {
                IO.Show(Mod);
            }
            else
            {
                IO.Compile(Mod, CompileError);
                Compiled = true;
                if (CompileError)
                {
                    IO.Show(Mod);
                }
            }
        }
        EvalGen.FinitGen;
        IO.CloseIn(Fix);
        IO.CloseOut(Mod);
    }
    EvalGen.FinitTest;
}

void Test()
{
    uint SaveHistory;
    IO.WriteText(IO.Msg, "SSweep testing ");
    IO.WriteString(IO.Msg, EAG.BaseName);
    IO.WriteText(IO.Msg, "   ");
    IO.Update(IO.Msg);
    if (EAG.Performed(Set))
    {
        EXCL(EAG.History, EAG.isSSweep);
        Init;
        SaveHistory = EAG.History;
        EAG.History = Set;
        GenerateMod(false);
        EAG.History = SaveHistory;
        if (!Error)
        {
            IO.WriteText(IO.Msg, "ok");
            INCL(EAG.History, EAG.isSSweep);
        }
        Finit;
    }
    IO.WriteLn(IO.Msg);
    IO.Update(IO.Msg);
}

void Generate()
{
    uint SaveHistory;
    IO.WriteText(IO.Msg, "SSweep writing ");
    IO.WriteString(IO.Msg, EAG.BaseName);
    IO.WriteText(IO.Msg, "   ");
    IO.Update(IO.Msg);
    Compiled = false;
    if (EAG.Performed(Set))
    {
        EXCL(EAG.History, EAG.isSSweep);
        Init;
        SaveHistory = EAG.History;
        EAG.History = Set;
        GenerateMod(true);
        EAG.History = SaveHistory;
        if (!Error)
        {
            INCL(EAG.History, EAG.isSSweep);
            INCL(EAG.History, EAG.hasEvaluator);
        }
        Finit;
    }
    if (!Compiled)
    {
        IO.WriteLn(IO.Msg);
    }
    IO.Update(IO.Msg);
}
