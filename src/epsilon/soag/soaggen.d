module epsilon.soag.soaggen;

import EAG = epsilon.eag;
import EmitGen = epsilon.emitgen;
import SLEAGGen = epsilon.sleaggen;
import epsilon.settings;
import io : Input, read;
import log;
import runtime;
import optimizer = epsilon.soag.optimizer;
import partition = epsilon.soag.partition;
import Protocol = epsilon.soag.protocol;
import SOAG = epsilon.soag.soag;
import VisitSeq = epsilon.soag.visitseq;
import std.bitmanip : BitArray;
import std.stdio;

private const cTab = 1;
private const firstAffixOffset = 0;
private const optimizedStorage = -1;
private const notApplied = -2;
private bool UseConst;
private bool UseRefCnt;
private bool Optimize;
private int[] LocalVars;
private int[] NodeName;
private int[] AffixOffset;
private int[] AffixVarCount;
private int[] SubTreeOffset;
private int[] FirstRule;
private int[] AffixAppls;
private File Out;
private int Indent;
private bool Close;

/**
 * SEM: Steuerung der Generierung
 */
public string Generate(Settings settings)
in (EAG.Performed(EAG.analysed | EAG.predicates))
{
    UseConst = !settings.c;
    UseRefCnt = !settings.r;
    Optimize = !settings.o;
    partition.Compute;
    VisitSeq.Generate;
    if (Optimize)
        optimizer.Optimize;
    info!"SOAG writing %s"(EAG.BaseName);
    if (Optimize)
        info!"optimize";
    else
        info!"don't optimize";
    Init;

    const fileName = GenerateModule(settings);

    EAG.History |= EAG.isSSweep;
    EAG.History |= EAG.hasEvaluator;
    return fileName;
}

/**
 * IN:  Regel
 * OUT: -
 * SEM: Berechnet im Feld NodeNames für alle Affixbaumanalysen der Regel
 *      die Namen der temp. Variablen für die Baumknoten;
 *      die maximale Variablenummer der Regel wird in LocalVars[] abgelegt
 */
private void ComputeNodeNames(int R) @nogc nothrow
{
    int Var;
    int ProcVar;
    int AP;
    int Node;
    int SO;
    int PBI;

    /**
     * IN: Knoten in NodeBuf[], Variablenname
     * OUT: -
     * SEM: Berechnet für jeden Knoten des Teilbaums NodeBuf[Node]
     *      die temp. Variable für die Baumanalyse oder -synthese
     */
    void Traverse(int Node, ref int Var)
    {
        int Node1;
        const  Arity = EAG.MAlt[EAG.NodeBuf[Node]].Arity;

        ++Var;
        NodeName[Node] = Var;
        for (size_t n = 1; n <= Arity; ++n)
        {
            Node1 = EAG.NodeBuf[Node + n];
            if (Node1 > 0)
            {
                if (UseConst && EAG.MAlt[EAG.NodeBuf[Node1]].Arity == 0)
                {
                    ++Var;
                    NodeName[Node1] = Var;
                }
                else
                {
                    Traverse(Node1, Var);
                }
            }
        }
    }

    LocalVars[R] = 0;
    for (AP = SOAG.Rule[R].AffOcc.Beg; AP <= SOAG.Rule[R].AffOcc.End; ++AP)
    {
        PBI = SOAG.AffOcc[AP].ParamBufInd;
        if (EAG.ParamBuf[PBI].isDef || UseRefCnt)
        {
            Var = 0;
            Node = EAG.ParamBuf[PBI].Affixform;
            if (Node > 0)
            {
                if (UseConst && EAG.MAlt[EAG.NodeBuf[Node]].Arity == 0)
                {
                    ++Var;
                    NodeName[Node] = Var;
                }
                else
                {
                    Traverse(Node, Var);
                }
            }
            if (Var > LocalVars[R])
            {
                LocalVars[R] = Var;
            }
        }
    }
    for (SO = SOAG.Rule[R].SymOcc.Beg; SO <= SOAG.Rule[R].SymOcc.End; ++SO)
    {
        if (SOAG.IsPredNont(SO))
        {
            Var = 0;
            ProcVar = 0;
            for (AP = SOAG.SymOcc[SO].AffOcc.Beg; AP <= SOAG.SymOcc[SO].AffOcc.End;
                    ++AP)
            {
                PBI = SOAG.AffOcc[AP].ParamBufInd;
                Node = EAG.ParamBuf[PBI].Affixform;
                if (!EAG.ParamBuf[PBI].isDef)
                {
                    if (Node > 0)
                    {
                        ++Var;
                        NodeName[Node] = Var;
                    }
                }
            }
            if (Var > LocalVars[R])
            {
                LocalVars[R] = Var;
            }
        }
    }
}

/**
 * IN:  Affixparameter
 * OUT: Affixposition
 * SEM: gibt die Affixposition zurück, zu der der Affixparameter korrespondiert
 */
private int GetCorrespondedAffPos(int AP) @nogc nothrow @safe
{
    const SO = SOAG.AffOcc[AP].SymOccInd;
    const AN = AP - SOAG.SymOcc[SO].AffOcc.Beg;

    return SOAG.Sym[SOAG.SymOcc[SO].SymInd].AffPos.Beg + AN;
}

/**
 * IN:  Regel
 * OUT: -
 * SEM: berechnet im Feld AffixOffset[], das parallel zu EAG.Var liegt,
 *      den Offset der Affixvariablen im Feld Var[] des generierten Compilers;
 *      alle nicht-applizierten Affixvariablen (AffixAppls[]=0) werden ausgelassen
 * PRE: AffixAppls[] muss berechnet sein
 */
private void ComputeAffixOffset(int R) @nogc nothrow @safe
{
    EAG.ScopeDesc Scope;
    EAG.Rule EAGRule;
    int A;
    int AP;
    int Offset;
    if (cast(SOAG.OrdRule) SOAG.Rule[R] !is null)
    {
        Scope = (cast(SOAG.OrdRule) SOAG.Rule[R]).Alt.Scope;
    }
    else
    {
        EAGRule = (cast(SOAG.EmptyRule) SOAG.Rule[R]).Rule;
        if (cast(EAG.Opt) EAGRule !is null)
            Scope = (cast(EAG.Opt) EAGRule).Scope;
        else if (cast(EAG.Rep) EAGRule !is null)
            Scope = (cast(EAG.Rep) EAGRule).Scope;
    }
    Offset = firstAffixOffset;
    for (A = Scope.Beg; A < Scope.End; ++A)
    {
        if (AffixAppls[A] > 0)
        {
            if (Optimize)
            {
                AP = GetCorrespondedAffPos(SOAG.DefAffOcc[A]);
                if (SOAG.StorageName[AP] == 0)
                {
                    AffixOffset[A] = Offset;
                    ++Offset;
                }
                else
                {
                    AffixOffset[A] = optimizedStorage;
                }
            }
            else
            {
                AffixOffset[A] = Offset;
                ++Offset;
            }
        }
        else
        {
            AffixOffset[A] = notApplied;
        }
    }
    AffixVarCount[R] = Offset - firstAffixOffset;
}

/**
 * SEM: liefert die echte Anzahl an Affixvariablen in der Regel;
 *      nur zur Information über die Optimierungleistung
 */
private int GetAffixCount(int R) @nogc nothrow @safe
{
    EAG.ScopeDesc Scope;
    EAG.Rule EAGRule;
    if (cast(SOAG.OrdRule) SOAG.Rule[R] !is null)
    {
        Scope = (cast(SOAG.OrdRule) SOAG.Rule[R]).Alt.Scope;
    }
    else
    {
        EAGRule = (cast(SOAG.EmptyRule) SOAG.Rule[R]).Rule;
        if (cast(EAG.Opt) EAGRule !is null)
            Scope = (cast(EAG.Opt) EAGRule).Scope;
        else if (cast(EAG.Rep) EAGRule !is null)
            Scope = (cast(EAG.Rep) EAGRule).Scope;
    }
    return Scope.End - Scope.Beg;
}

/**
 * IN:  -
 * OUT: Hyper-Arity-Konstante
 * SEM: Liefert die Arity-Konstante für den Ableitungsbaum, der durch den Parser erzeugt wird;
 *      müsste eigentlich von SLEAG geliefert werden (in SSweep wurde es auch intern definiert,
 *      deshalb wird es hier für spätere Module exportiert)
 */
private int HyperArity() nothrow
{
    const Nonts = EAG.All - EAG.Pred;
    int Max = 0;
    int i;

    foreach (N; Nonts.bitsSet)
    {
        EAG.Alt A = EAG.HNont[N].Def.Sub;

        i = 0;
        do
        {
            ++i;
            A = A.Next;
        }
        while (A !is null);
        if (cast(EAG.Opt) EAG.HNont[N].Def !is null || cast(EAG.Rep) EAG.HNont[N].Def !is null)
            ++i;
        if (i > Max)
            Max = i;
    }
    i = 1;
    while (i <= Max)
        i = i * 2;
    return i;
}

/**
 * SEM: Initialisierung der Datenstrukturen des Moduls
 */
private void Init() nothrow
{
    int R;
    int SO;
    int S;
    int Offset;

    LocalVars = new int[SOAG.NextRule];
    AffixVarCount = new int[SOAG.NextRule];
    AffixOffset = new int[EAG.NextVar];
    NodeName = new int[EAG.NextNode];
    SubTreeOffset = new int[SOAG.NextSymOcc];
    FirstRule = new int[SOAG.NextSym];
    AffixAppls = new int[EAG.NextVar];
    for (size_t i = SOAG.firstRule; i < SOAG.NextRule; ++i)
    {
        LocalVars[i] = 0;
        AffixVarCount[i] = -1;
    }
    for (size_t i = EAG.firstNode; i < EAG.NextNode; ++i)
    {
        NodeName[i] = -1;
    }
    for (size_t i = EAG.firstVar; i < EAG.NextVar; ++i)
    {
        EAG.Var[i].Def = false;
        AffixAppls[i] = SOAG.AffixApplCnt[i];
    }
    for (R = SOAG.firstRule; R < SOAG.NextRule; ++R)
    {
        Offset = 0;
        for (SO = SOAG.Rule[R].SymOcc.Beg + 1; SO <= SOAG.Rule[R].SymOcc.End; ++SO)
        {
            if (!SOAG.IsPredNont(SO))
            {
                ++Offset;
                SubTreeOffset[SO] = Offset;
            }
        }
    }
    for (S = SOAG.firstSym; S < SOAG.NextSym; ++S)
    {
        SO = SOAG.Sym[S].FirstOcc;
        if (SO != SOAG.nil)
        {
            R = SOAG.SymOcc[SO].RuleInd;
            while (SO != SOAG.Rule[R].SymOcc.Beg)
            {
                SO = SOAG.SymOcc[SO].Next;
                R = SOAG.SymOcc[SO].RuleInd;
            }
            SO = SOAG.SymOcc[SO].Next;
            while (R >= SOAG.firstRule && S == SOAG.SymOcc[SOAG.Rule[R].SymOcc.Beg].SymInd)
            {
                FirstRule[S] = R;
                --R;
            }
        }
    }
}

private void Ind() @safe
{
    for (size_t i = 1; i <= Indent; ++i)
        Out.write("    ");
}

private void WrS(T)(T String)
{
    Out.write(String);
}

private void WrI(int Int) @safe
{
    Out.write(Int);
}

private void WrSI(string String, int Int) @safe
{
    Out.write(String);
    Out.write(Int);
}

void WrIS(int Int, string String) @safe
{
    Out.write(Int);
    Out.write(String);
}

private void WrSIS(string String1, int Int, string String2) @safe
{
    Out.write(String1);
    Out.write(Int);
    Out.write(String2);
}

private void GenHeapInc(int n) @safe
{
    if (n != 0)
    {
        if (n == 1)
            WrS("++NextHeap; \n");
        else
            WrSIS("NextHeap += ", n, ";\n");
    }
}

private void GenVar(int Var) @safe
{
    WrSI("V", Var);
}

private void GenHeap(int Var, int Offset) @safe
{
    WrS("Heap[");
    if (Var > 0)
        GenVar(Var);
    else
        WrS("NextHeap");
    if (Offset > 0)
        WrSI(" + ", Offset);
    else if (Offset < 0)
        WrSI(" - ", -Offset);
    WrS("]");
}

private void GenOverflowGuard(int n) @safe
{
    if (n > 0)
        WrSIS("if (NextHeap >= Heap.length - ", n, ") EvalExpand;\n");
}

/**
 * IN:  Symbol, Nummer eines Affixparameter relativ zum Symbolvorkommen
 * OUT: -
 * SEM: Generierung eines Zugriffs auf die Instanz einer Affixposition
 */
private void GenAffPos(int S, int AN) @safe
{
    WrSIS("AffPos[S", S, " + ");
    WrIS(AN, "]");
}

/**
 * IN: Affixnummer
 * OUT: -
 * SEM: Generiert einen Zugriff auf den Inhalt eines Affixes
 */
private void GenAffix(int V) @safe
in (AffixOffset[V] != notApplied)
{
    int AP;

    if (AffixOffset[V] == optimizedStorage)
    {
        AP = GetCorrespondedAffPos(SOAG.DefAffOcc[V]);
        if (SOAG.StorageName[AP] > 0)
            WrSIS("Stacks.Top(Stack", SOAG.StorageName[AP], ") ");
        else
            WrSI("GV", -SOAG.StorageName[AP]);
    }
    else
    {
        WrSIS("Var[VI + ", AffixOffset[V], "]");
    }
}

/**
 * IN: Affix
 * OUT: -
 * SEM: Generierung einer Zuweisung zu einer Instanz einer Affixvariable;
 *      nur in Kombination mit der Prozedur GenClose zu verwenden
 */
private void GenAffixAssign(int V) @safe
in (AffixOffset[V] != notApplied)
{
    int AP;

    if (AffixOffset[V] == optimizedStorage)
    {
        AP = GetCorrespondedAffPos(SOAG.DefAffOcc[V]);
        if (SOAG.StorageName[AP] > 0)
        {
            WrSIS("Stacks.Push(Stack", SOAG.StorageName[AP], ", ");
            Close = true;
        }
        else
        {
            WrSIS("GV", -SOAG.StorageName[AP], " = ");
            Close = false;
        }
    }
    else
    {
        WrSIS("Var[VI + ", AffixOffset[V], "] = ");
        Close = false;
    }
}

private void GenClose() @safe
{
    if (Close)
        WrS("); ");
    else
        WrS("; ");
}

/**
 * IN: Affixvariable oder (< 0) lokale Variable
 * OUT: -
 * SEM: Generiert eine Erhöhung des Referenzzählers des Knotens auf den das Affixes
 *      bzw. der Index verweist, im Falle eines Stacks wird globale Var. RefIncVar verwendet
 */
private void GenIncRefCnt(int Var) @safe
{
    WrS("Heap[");
    if (Var < 0)
        GenVar(-Var);
    else
        GenAffix(Var);
    WrS("] += refConst;\n");
}

/**
 * IN: Affixvariable
 * OUT: -
 * SEM: generiert die Freigabe des alloziierten Speichers,
 *      wenn die Affixvariable das letzte mal appliziert wurde (AffixAppls = 0)
 */
private void GenFreeAffix(int V) @safe
{
    if (AffixAppls[V] == 0)
    {
        Ind;
        WrS("FreeHeap(");
        GenAffix(V);
        WrS(");\n");
    }
}

/**
 * IN: Affixvariable
 * OUT: -
 * SEM: generiert die Kellerspeicherfreigabe,
 *      wenn die Affixvariable das letzte mal appliziert wurde (AffixAppls = 0)
 */
private void GenPopAffix(int V) @safe
{
    if (AffixAppls[V] == 0)
    {
        if (AffixOffset[V] == optimizedStorage)
        {
            const AP = GetCorrespondedAffPos(SOAG.DefAffOcc[V]);

            if (SOAG.StorageName[AP] > 0)
            {
                Ind;
                WrSIS("Stacks.Pop(Stack", SOAG.StorageName[AP], ");\n");
            }
            else
            {
                Ind;
                WrSIS("GV", -SOAG.StorageName[AP], " = -1;\n");
            }
        }
    }
}

/**
 * IN: Symbolvorkommen
 * OUT: -
 * SEM: Generierung der Syntheseaktionen eines Besuchs für die besuchsrelevanten Affixparameter eines Symbolvorkommens
 */
private void GenSynPred(int SymOccInd, int VisitNo)
{
    int Node;
    int S;
    int Offset;
    int AP;
    int AN;
    int V;
    int SN;
    int P;
    bool IsPred;

    /**
     * IN: Knoten des Affixbaumes, Offset des nächsten freien Heap-Elementes
     * OUT: -
     * SEM: Traversierung eines Affixbaumes und Ausgabe der Syntheseaktionen für den zu generierenden Compiler
     */
    void GenSynTraverse(int Node, ref int Offset)
    {
        int Offset1;
        int Node1;
        int n;
        int V;
        int Alt;
        Alt = EAG.NodeBuf[Node];
        Ind;
        GenHeap(-1, Offset);
        WrSIS(" = ", SLEAGGen.NodeIdent[Alt], ";\n");
        Offset1 = Offset;
        Offset += 1 + EAG.MAlt[Alt].Arity;
        for (n = 1; n <= EAG.MAlt[Alt].Arity; ++n)
        {
            Node1 = EAG.NodeBuf[Node + n];
            if (Node1 < 0)
            {
                V = -Node1;
                if (!EAG.Var[V].Def)
                {
                    SOAG.Error(SOAG.abnormalError, "eSOAGGen.GenSynTraverse: Affix nicht definiert.");
                }
                else
                {
                    Ind;
                    GenHeap(-1, Offset1 + n);
                    WrS(" = ");
                    GenAffix(V);
                    WrS(";\n");
                    --AffixAppls[V];
                    if (UseRefCnt)
                        GenFreeAffix(V);
                    if (Optimize)
                        GenPopAffix(V);
                }
            }
            else
            {
                Ind;
                GenHeap(-1, Offset1 + n);
                WrS(" = ");
                if (UseConst && EAG.MAlt[EAG.NodeBuf[Node1]].Arity == 0)
                {
                    WrIS(SLEAGGen.Leaf[EAG.NodeBuf[Node1]], ";\n");
                }
                else
                {
                    WrSIS("NextHeap + ", Offset, ";\n");
                    GenSynTraverse(Node1, Offset);
                }
            }
        }
    }

    /**
     * IN: Knoten des Affixbaumes
     * OUT: -
     * SEM: Traversierung eines Affixbaumes und Ausgabe der Syntheseaktionen mit Referenzzähler-Verfahren
     *      für den zu generierenden Compiler
     */
    void GenSynTraverseRefCnt(int Node)
    {
        int Node1;
        int n;
        int V;
        int Alt;
        Alt = EAG.NodeBuf[Node];
        Ind;
        GenHeap(NodeName[Node], 0);
        WrSIS(" = ", SLEAGGen.NodeIdent[Alt], ";\n");
        for (n = 1; n <= EAG.MAlt[Alt].Arity; ++n)
        {
            Node1 = EAG.NodeBuf[Node + n];
            if (Node1 < 0)
            {
                V = -Node1;
                if (!EAG.Var[V].Def)
                {
                    SOAG.Error(SOAG.abnormalError, "eSOAGGen.GenSynTraverse: Affix nicht definiert.");
                }
                else
                {
                    Ind;
                    GenHeap(NodeName[Node], n);
                    WrS(" = ");
                    GenAffix(V);
                    WrS("; ");
                    --AffixAppls[V];
                    if (AffixAppls[V] > 0)
                        GenIncRefCnt(V);
                    else
                        WrS("// komplementäre Referenzzählerbehandlung\n");
                    if (Optimize)
                        GenPopAffix(V);
                }
            }
            else
            {
                Ind;
                if (UseConst && EAG.MAlt[EAG.NodeBuf[Node1]].Arity == 0)
                {
                    GenHeap(NodeName[Node], n);
                    WrSIS(" = ", SLEAGGen.Leaf[EAG.NodeBuf[Node1]], "; ");
                    WrSIS("Heap[", SLEAGGen.Leaf[EAG.NodeBuf[Node1]], "] += refConst;\n");
                }
                else
                {
                    WrSIS("GetHeap(", EAG.MAlt[EAG.NodeBuf[Node1]].Arity, ", ");
                    GenVar(NodeName[Node1]);
                    WrS(");\n");
                    GenSynTraverseRefCnt(Node1);
                    Ind;
                    GenHeap(NodeName[Node], n);
                    WrS(" = ");
                    GenVar(NodeName[Node1]);
                    WrS(";\n");
                }
            }
        }
    }

    S = SOAG.SymOcc[SymOccInd].SymInd;
    IsPred = VisitNo == -1;
    for (AP = SOAG.SymOcc[SymOccInd].AffOcc.Beg; AP <= SOAG.SymOcc[SymOccInd].AffOcc.End;
            ++AP)
    {
        AN = AP - SOAG.SymOcc[SymOccInd].AffOcc.Beg;
        P = SOAG.AffOcc[AP].ParamBufInd;
        if (!EAG.ParamBuf[P].isDef && (VisitSeq.GetVisitNo(AP) == VisitNo || IsPred))
        {
            Node = EAG.ParamBuf[P].Affixform;
            SN = SymOccInd - SOAG.Rule[SOAG.SymOcc[SymOccInd].RuleInd].SymOcc.Beg;
            if (Node < 0)
            {
                V = -Node;
                if (!EAG.Var[V].Def)
                {
                    SOAG.Error(SOAG.abnormalError, "eSOAGGen.GenSynTraverse: Affix nicht definiert.");
                }
                else if (!IsPred)
                {
                    Ind;
                    GenAffPos(S, AN);
                    WrS(" = ");
                    GenAffix(V);
                    WrS("; ");
                    --AffixAppls[V];
                    if (UseRefCnt && AffixAppls[V] > 0)
                        GenIncRefCnt(V);
                    else
                        WrS("// komplementäre Referenzzählerbehandlung\n");
                    if (Optimize)
                        GenPopAffix(V);
                    WrS("\n");
                }
            }
            else
            {
                Ind;
                if (UseConst && SLEAGGen.AffixPlace[P] >= 0)
                {
                    GenAffPos(S, AN);
                    WrSI(" = ", SLEAGGen.AffixPlace[P]);
                    if (UseRefCnt)
                        WrSIS("; Heap[", SLEAGGen.AffixPlace[P], "] += refConst");
                    WrS(";\n");
                }
                else if (UseRefCnt)
                {
                    WrSIS("GetHeap(", EAG.MAlt[EAG.NodeBuf[Node]].Arity, ", ");
                    GenVar(NodeName[Node]);
                    WrS(");\n");
                    GenSynTraverseRefCnt(Node);
                    Ind;
                    GenAffPos(S, AN);
                    WrS(" = ");
                    GenVar(NodeName[Node]);
                    WrS(";\n");
                }
                else
                {
                    GenOverflowGuard(SLEAGGen.AffixSpace[P]);
                    Ind;
                    GenAffPos(S, AN);
                    WrS(" = NextHeap;\n");
                    Offset = 0;
                    GenSynTraverse(Node, Offset);
                    Ind;
                    GenHeapInc(Offset);
                }
            }
        }
    }
}

/**
 * IN: Symbolvorkommen, Visit-Nummer
 * OUT: -
 * SEM: Generierung der Analyseaktionen eines Besuchs für die besuchsrelevanten Affixparameter eines Symbolvorkommens
 */
private void GenAnalPred(int SymOccInd, int VisitNo) @safe
{
    int S;
    int AP;
    int AN;
    int Node;
    int V;
    int SN;
    bool IsPred;
    bool PosNeeded;

    void GenEqualErrMsg(int Var)
    {
        WrS("\"'");
        WrS(EAG.VarRepr(Var));
        WrS("' failed in '");
        WrS(EAG.NamedHNontRepr(SOAG.SymOcc[SymOccInd].SymInd));
        WrS("'\"");
    }

    void GenAnalErrMsg()
    {
        WrS("\"");
        WrS(EAG.NamedHNontRepr(SOAG.SymOcc[SymOccInd].SymInd));
        WrS("\"");
    }

    /**
     * IN:  Index auf EAG.Var[] des def. Affixes, Index auf NodeName[] und Nr. des Sohnes im Heap
     * OUT: -
     * SEM: Generiert einen Vergleich zwischen einer Variable eines def. Affixes und einem Baumeintrag
     */
    void GenEqualPred(int V, int Node, int n)
    {
        WrS("Eq(");
        GenHeap(NodeName[Node], n);
        WrS(", ");
        GenAffix(V);
        WrS(", ");
        GenEqualErrMsg(V);
        WrS(");\n");
    }

    /**
     * IN:  zwei Indexe auf EAG.Var[]
     * OUT: -
     * SEM: Generiert einen Vergleich zwischen zwei Variablen der Felder Var[] (gen. Compiler)
     */
    void GenUnequalPred(int V1, int V2)
    {
        WrS("UnEq(");
        GenAffix(V1);
        WrS(", ");
        GenAffix(V2);
        WrS(", ");
        if (EAG.Var[V1].Num < 0)
            GenEqualErrMsg(V1);
        else
            GenEqualErrMsg(V2);
        WrS(");\n");
    }

    /**
     * SEM: Generierung einer Positionszuweisung, wenn notwendig
     */
    void GenPos(ref bool PosNeeded)
    {
        if (PosNeeded)
        {
            Ind;
            WrSIS("Pos = SemTree[TreeAdr + ", SubTreeOffset[SymOccInd], "].Pos;\n");
            PosNeeded = false;
        }
    }

    /**
     * IN: Knoten des Affixbaumes
     * OUT: -
     * SEM: Traversierung eines Affixbaumes und Ausgabe der Analyseaktionen für den zu generierenden Compiler
     */
    void GenAnalTraverse(int Node)
    {
        int Node1;
        int n;
        int V;
        int Alt;
        Ind;
        WrS("if (");
        Alt = EAG.NodeBuf[Node];
        if (UseConst && EAG.MAlt[Alt].Arity == 0)
        {
            GenVar(NodeName[Node]);
            WrSI(" != ", SLEAGGen.Leaf[Alt]);
        }
        else
        {
            GenHeap(NodeName[Node], 0);
            if (UseRefCnt)
                WrS(".MOD(refConst)");
            WrSI(" != ", SLEAGGen.NodeIdent[Alt]);
        }
        WrS(") AnalyseError(");
        GenVar(NodeName[Node]);
        WrS(", ");
        GenAnalErrMsg;
        WrS("); \n");
        for (n = 1; n <= EAG.MAlt[Alt].Arity; ++n)
        {
            Node1 = EAG.NodeBuf[Node + n];
            if (Node1 < 0)
            {
                V = -Node1;
                if (EAG.Var[V].Def)
                {
                    Ind;
                    GenEqualPred(V, Node, n);
                    --AffixAppls[V];
                    if (UseRefCnt)
                        GenFreeAffix(V);
                    if (Optimize)
                        GenPopAffix(V);
                }
                else
                {
                    EAG.Var[V].Def = true;
                    if (AffixOffset[V] != notApplied)
                    {
                        Ind;
                        GenAffixAssign(V);
                        GenHeap(NodeName[Node], n);
                        GenClose;
                        if (EAG.Var[EAG.Var[V].Neg].Def)
                        {
                            WrS("\n");
                            Ind;
                            GenUnequalPred(EAG.Var[V].Neg, V);
                            --AffixAppls[EAG.Var[V].Neg];
                            --AffixAppls[V];
                            if (UseRefCnt && AffixAppls[V] > 0)
                                GenIncRefCnt(V);
                            if (UseRefCnt)
                                GenFreeAffix(EAG.Var[V].Neg);
                            if (Optimize)
                            {
                                GenPopAffix(EAG.Var[V].Neg);
                                GenPopAffix(V);
                            }
                        }
                        else if (UseRefCnt)
                        {
                            GenIncRefCnt(V);
                        }
                    }
                }
            }
            else
            {
                Ind;
                GenVar(NodeName[Node1]);
                WrS(" = ");
                GenHeap(NodeName[Node], n);
                WrS(";\n");
                GenAnalTraverse(Node1);
            }
        }
    }

    S = SOAG.SymOcc[SymOccInd].SymInd;
    IsPred = VisitNo == -1;
    PosNeeded = !IsPred;
    for (AP = SOAG.SymOcc[SymOccInd].AffOcc.Beg; AP <= SOAG.SymOcc[SymOccInd].AffOcc.End;
            ++AP)
    {
        AN = AP - SOAG.SymOcc[SymOccInd].AffOcc.Beg;
        if (EAG.ParamBuf[SOAG.AffOcc[AP].ParamBufInd].isDef
                && (VisitSeq.GetVisitNo(AP) == VisitNo || IsPred))
        {
            Node = EAG.ParamBuf[SOAG.AffOcc[AP].ParamBufInd].Affixform;
            SN = SymOccInd - SOAG.Rule[SOAG.SymOcc[SymOccInd].RuleInd].SymOcc.Beg;
            if (Node < 0)
            {
                V = -Node;
                if (EAG.Var[V].Def)
                {
                    GenPos(PosNeeded);
                    Ind;
                    WrS("Eq(");
                    GenAffPos(S, AN);
                    WrS(", ");
                    GenAffix(V);
                    WrS(", ");
                    GenEqualErrMsg(V);
                    WrS(");\n");
                    --AffixAppls[V];
                    if (UseRefCnt)
                        GenFreeAffix(V);
                    if (Optimize)
                        GenPopAffix(V);
                    if (UseRefCnt)
                    {
                        Ind;
                        WrS("FreeHeap(");
                        GenAffPos(S, AN);
                        WrS(");\n");
                    }
                }
                else
                {
                    EAG.Var[V].Def = true;
                    if (!IsPred)
                    {
                        if (AffixOffset[V] != notApplied)
                        {
                            Ind;
                            GenAffixAssign(V);
                            GenAffPos(S, AN);
                            GenClose;
                            if (UseRefCnt)
                                WrS("// komplementäre Referenzzählerbehandlung");
                            WrS("\n");
                        }
                    }
                    if (EAG.Var[EAG.Var[V].Neg].Def)
                    {
                        GenPos(PosNeeded);
                        Ind;
                        WrS("UnEq(");
                        GenAffix(EAG.Var[V].Neg);
                        WrS(", ");
                        GenAffix(V);
                        WrS(", ");
                        GenEqualErrMsg(V);
                        WrS(");\n");
                        --AffixAppls[EAG.Var[V].Neg];
                        --AffixAppls[V];
                        if (UseRefCnt)
                        {
                            GenFreeAffix(EAG.Var[V].Neg);
                            GenFreeAffix(V);
                        }
                        if (Optimize)
                        {
                            GenPopAffix(EAG.Var[V].Neg);
                            GenPopAffix(V);
                        }
                    }
                }
            }
            else
            {
                GenPos(PosNeeded);
                Ind;
                GenVar(NodeName[Node]);
                WrS(" = ");
                GenAffPos(S, AN);
                WrS(";\n");
                GenAnalTraverse(Node);
                if (UseRefCnt)
                {
                    Ind;
                    WrS("FreeHeap(");
                    GenAffPos(S, AN);
                    WrS(");\n");
                }
            }
        }
    }
}

/**
 * IN: Symbolvorkommen, Visit-Nummer
 * OUT: -
 * SEM: Generierung eines Aufrufes der Prozedur 'Visit' für den zu generierenden Compiler
 */
private void GenVisitCall(int SO, int VisitNo) @safe
{
    Ind;
    WrSIS("Visit(TreeAdr + ", SubTreeOffset[SO], ", ");
    WrIS(VisitNo, ");\n");
}

/**
 * SEM: generiert nur Kommentar
 */
private void GenLeave(int VisitNo) @safe
{
    Ind;
    WrSIS("// Leave; VisitNo: ", VisitNo, "\n");
}

/**
 * IN: Symbolvorkommen eines Prädikates
 * OUT: -
 * SEM: Generierung des Aufrufes einer Prädikatprozedur
 */
private void GenPredCall(int SO) @safe
{
    int S;
    int AP;
    int AN;
    int AP1;
    int Node;
    int V;
    if (UseRefCnt)
    {
        for (AP = SOAG.SymOcc[SO].AffOcc.Beg; AP <= SOAG.SymOcc[SO].AffOcc.End; ++AP)
        {
            if (!EAG.ParamBuf[SOAG.AffOcc[AP].ParamBufInd].isDef)
            {
                AN = AP - SOAG.SymOcc[SO].AffOcc.Beg;
                V = -EAG.ParamBuf[SOAG.AffOcc[AP].ParamBufInd].Affixform;
                if (V > 0)
                {
                    Ind;
                    GenIncRefCnt(V);
                }
            }
        }
    }
    S = SOAG.SymOcc[SO].SymInd;
    Ind;
    WrSIS("Check", S, "(\"");
    WrS(EAG.NamedHNontRepr(S));
    WrS("\", ");
    for (AP = SOAG.SymOcc[SO].AffOcc.Beg; AP <= SOAG.SymOcc[SO].AffOcc.End; ++AP)
    {
        Node = EAG.ParamBuf[SOAG.AffOcc[AP].ParamBufInd].Affixform;
        AN = AP - SOAG.SymOcc[SO].AffOcc.Beg;
        V = -Node;
        if (EAG.ParamBuf[SOAG.AffOcc[AP].ParamBufInd].isDef)
        {
            if (V > 0 && SOAG.DefAffOcc[V] == AP)
            {
                if (Optimize && AffixOffset[V] == optimizedStorage)
                {
                    AP1 = GetCorrespondedAffPos(SOAG.DefAffOcc[V]);
                    if (SOAG.StorageName[AP1] > 0)
                        GenAffPos(S, AN);
                    else
                        WrSI("GV", -SOAG.StorageName[AP1]);
                }
                else if (AffixOffset[V] == notApplied)
                {
                    GenAffPos(S, AN);
                }
                else
                {
                    GenAffix(V);
                }
            }
            else
            {
                GenAffPos(S, AN);
            }
        }
        else
        {
            if (Node > 0)
                GenAffPos(S, AN);
            else
                GenAffix(V);
        }
        if (AP != SOAG.SymOcc[SO].AffOcc.End)
            WrS(", ");
        else
            WrS(");\n");
    }
    for (AP = SOAG.SymOcc[SO].AffOcc.Beg; AP <= SOAG.SymOcc[SO].AffOcc.End; ++AP)
    {
        AN = AP - SOAG.SymOcc[SO].AffOcc.Beg;
        V = -EAG.ParamBuf[SOAG.AffOcc[AP].ParamBufInd].Affixform;
        if (V > 0)
        {
            if (EAG.ParamBuf[SOAG.AffOcc[AP].ParamBufInd].isDef)
            {
                if (AffixOffset[V] == optimizedStorage)
                {
                    AP1 = GetCorrespondedAffPos(SOAG.DefAffOcc[V]);
                    if (SOAG.StorageName[AP1] > 0)
                    {
                        Ind;
                        WrSIS("Stacks.Push(Stack", SOAG.StorageName[AP1], ", ");
                        GenAffPos(S, AN);
                        WrS(");\n");
                    }
                }
                else if (AffixOffset[V] == notApplied)
                {
                    Ind;
                    WrS("FreeHeap(");
                    GenAffPos(S, AN);
                    WrS("); // Dummy-Variable\n");
                }
            }
            else
            {
                --AffixAppls[V];
                if (UseRefCnt)
                    GenFreeAffix(V);
                if (Optimize)
                    GenPopAffix(V);
            }
        }
    }
}

/**
 * IN:  Regel
 * OUT: -
 * SEM: Generierung der Variablendeklarationen einer Regel
 */
private void GenVarDecls(int R) @safe
{
    WrS("IndexType TreeAdr;\n");
    WrS("IndexType VI;\n");
    WrS("SemTreeEntry S;\n");
    if (LocalVars[R] > 0)
    {
        for (int i = 1; i <= LocalVars[R]; ++i)
        {
            WrS("HeapType ");
            GenVar(i);
            WrS(";\n");
        }
    }
}

/**
 * IN:  Regel, Nummer des Visit-Sequenz-Eintrages, Notwendigkeit der Positionszuweisung
 * OUT: -
 * SEM: Generierung der Positionszuweisung vor Prädikatprozeduraufrufen;
 *      zugewiesen wird die Position des vorhergehenden Visits
 */
private void GenPredPos(int R, int i, ref bool PosNeeded) @safe
{
    int k;

    if (PosNeeded)
    {
        --i;
        while (cast(SOAG.Visit) SOAG.VS[i] is null && cast(SOAG.Leave) SOAG.VS[i] is null && i > SOAG.Rule[R].VS.Beg)
            --i;
        if (cast(SOAG.Visit) SOAG.VS[i] !is null)
            k = SubTreeOffset[(cast(SOAG.Visit) SOAG.VS[i]).SymOcc];
        else
            k = SOAG.Rule[R].SymOcc.Beg;
        Ind;
        WrSIS("Pos = SemTree[TreeAdr + ", k, "].Pos;\n");
        PosNeeded = false;
    }
}

/**
 * IN: Regelnummer
 * OUT: -
 * SEM: Generiert Code für die Visit-Sequenzen einer Regel
 */
private void GenVisitRule(int R)
{
    int SO;
    int VN;
    int VisitNo;
    int i;
    int S;
    int NontCnt;
    bool onlyoneVisit;
    bool first;
    bool PosNeeded;

    Indent = 0;
    WrSIS("void VisitRule", R, "(long Symbol, int VisitNo)\n");
    WrS("/*\n");
    Protocol.Out = Out;
    WrS(" * ");
    Protocol.WriteRule(R);
    WrS(" */\n");
    Protocol.Out = stdout;
    WrS("{\n");
    GenVarDecls(R);
    Indent += cTab;
    NontCnt = 1;
    for (SO = SOAG.Rule[R].SymOcc.Beg + 1; SO <= SOAG.Rule[R].SymOcc.End; ++SO)
        if (!SOAG.IsPredNont(SO))
            ++NontCnt;
    SO = SOAG.Rule[R].SymOcc.Beg;
    Ind;
    WrS("if (VisitNo == syntacticPart)\n");
    Ind;
    WrS("{\n");
    Indent += cTab;
    Ind;
    WrSIS("if (NextSemTree >= SemTree.length - ", NontCnt, ") ExpandSemTree;\n");
    Ind;
    WrS("TreeAdr = SemTree[Symbol].Adr;\n");
    Ind;
    WrS("SemTree[Symbol].Adr = NextSemTree;\n");
    Ind;
    WrS("SemTree[Symbol].Pos = PosTree[TreeAdr];\n");
    Ind;
    WrSIS("AffixVarCount += ", GetAffixCount(R), ";\n");
    if (AffixVarCount[R] > 0)
    {
        Ind;
        WrSIS("if (NextVar >= Var.length - ", AffixVarCount[R], ") ExpandVar;\n");
        Ind;
        WrSIS("SemTree[Symbol].VarInd = NextVar; NextVar += ", AffixVarCount[R], ";\n");
    }
    else
    {
        Ind;
        WrS("SemTree[Symbol].VarInd = nil;\n");
    }
    Ind;
    WrS("SemTree[NextSemTree] = SemTree[Symbol];\n");
    Ind;
    WrS("++NextSemTree;\n");
    for (SO = SOAG.Rule[R].SymOcc.Beg + 1; SO <= SOAG.Rule[R].SymOcc.End; ++SO)
    {
        if (!SOAG.IsPredNont(SO))
        {
            Ind;
            WrS("S = new SemTreeEntry;\n");
            Ind;
            WrSIS("S.Adr = Tree[TreeAdr + ", SubTreeOffset[SO], "];\n");
            Ind;
            WrSIS("S.Rule = ", FirstRule[SOAG.SymOcc[SO].SymInd] - 1, " + MOD(Tree[S.Adr], hyperArityConst);\n");
            Ind;
            WrS("SemTree[NextSemTree] = S; ++NextSemTree;\n");
        }
    }
    first = true;
    for (SO = SOAG.Rule[R].SymOcc.Beg + 1; SO <= SOAG.Rule[R].SymOcc.End; ++SO)
    {
        if (!SOAG.IsPredNont(SO))
        {
            if (first)
            {
                Ind;
                WrS("TreeAdr = SemTree[Symbol].Adr;\n");
                first = false;
            }
            Ind;
            WrSIS("Visit(TreeAdr + ", SubTreeOffset[SO], ", syntacticPart);\n");
        }
    }
    Indent -= cTab;
    Ind;
    WrS("}\n");
    Ind;
    WrS("else\n");
    Ind;
    WrS("{\n");
    Indent += cTab;
    Ind;
    WrS("TreeAdr = SemTree[Symbol].Adr;\n");
    if (AffixVarCount[R] > 0)
    {
        Ind;
        WrS("VI = SemTree[Symbol].VarInd;\n\n");
    }
    if (VisitSeq.GetMaxVisitNo(SOAG.Rule[R].SymOcc.Beg) == 1)
    {
        onlyoneVisit = true;
    }
    else
    {
        onlyoneVisit = false;
        Ind;
        WrS("switch (VisitNo)\n");
        Ind;
        WrS("{\n");
        Indent += cTab;
        Ind;
        WrS("case 1:\n");
        Indent += cTab;
    }
    VisitNo = 1;
    PosNeeded = true;
    Ind;
    WrS("// Visit-beginnende Analyse\n");
    GenAnalPred(SOAG.Rule[R].SymOcc.Beg, VisitNo);
    for (i = SOAG.Rule[R].VS.Beg; i <= SOAG.Rule[R].VS.End; ++i)
    {
        if (cast(SOAG.Visit) SOAG.VS[i] !is null)
        {
            SO = (cast(SOAG.Visit) SOAG.VS[i]).SymOcc;
            S = SOAG.SymOcc[SO].SymInd;
            VN = (cast(SOAG.Visit) SOAG.VS[i]).VisitNo;
            Ind;
            WrS("// Synthese\n");
            GenSynPred(SO, VN);
            GenVisitCall(SO, VN);
            Ind;
            WrS("// Analyse\n");
            GenAnalPred(SO, VN);
            WrS("\n");
            PosNeeded = true;
        }
        else if (cast(SOAG.Call) SOAG.VS[i] !is null)
        {
            SO = (cast(SOAG.Call) SOAG.VS[i]).SymOcc;
            Ind;
            WrS("// Synthese\n");
            GenSynPred(SO, -1);
            GenPredPos(R, i, PosNeeded);
            GenPredCall(SO);
            Ind;
            WrS("// Analyse\n");
            GenAnalPred(SO, -1);
            WrS("\n");
        }
        else if (cast(SOAG.Leave) SOAG.VS[i] !is null)
        {
            SO = SOAG.Rule[R].SymOcc.Beg;
            VN = (cast(SOAG.Leave) SOAG.VS[i]).VisitNo;

            assert(VN == VisitNo);

            Ind;
            WrS("// Visit-abschließende Synthese\n");
            GenSynPred(SO, VisitNo);
            GenLeave(VisitNo);
            if (VisitNo < VisitSeq.GetMaxVisitNo(SO))
            {
                Ind;
                WrS("break;\n");
                Indent -= cTab;
                ++VisitNo;
                PosNeeded = true;
                Ind;
                WrSIS("case ", VisitNo, ":\n");
                Indent += cTab;
                Ind;
                WrS("// Visit-beginnende Analyse\n");
                GenAnalPred(SO, VisitNo);
            }
            else
            {
                if (!onlyoneVisit)
                {
                    Ind;
                    WrS("break;\n");
                }
                Indent -= cTab;
            }
        }
    }
    if (!onlyoneVisit)
    {
        Ind;
        WrS("default: assert(0);\n");
        Indent -= cTab;
        Ind;
        WrS("}\n");
        Indent -= cTab;
    }
    Ind;
    WrS("}\n");
    WrS("}\n\n");
}

/**
 * SEM: Generierung der Prozedur 'Visit', die die Besuche auf die entsprechenden Regeln verteilt
 */
private void GenVisit()
{
    Indent = 0;
    WrS("void Visit(long Symbol, int VisitNo)\n");
    WrS("{\n");
    Indent += cTab;
    Ind;
    WrS("switch (SemTree[Symbol].Rule)\n");
    Ind;
    WrS("{\n");
    Indent += cTab;
    for (int R = SOAG.firstRule; R < SOAG.NextRule; ++R)
    {
        if (SOAG.IsEvaluatorRule(R))
        {
            Ind;
            WrSIS("case ", R, ": ");
            WrSIS("VisitRule", R, "(Symbol, VisitNo); break;\n");
        }
    }
    Ind;
    WrS("default: assert(0);\n");
    Indent -= cTab;
    Ind;
    WrS("}\n");
    WrS("}\n\n");
}

/**
 * SEM: Generierung der Konstanten für den Zugriff auf AffPos[] im generierten Compiler
 */
private void GenConstDeclarations() @safe
{
    for (int S = SOAG.firstSym; S < SOAG.NextSym; ++S)
    {
        WrSIS("const S", S, " = ");
        WrIS(SOAG.Sym[S].AffPos.Beg, "; // ");
        WrS(EAG.HNontRepr(S));
        WrS("\n");
    }
}

/**
 * SEM: Generierung der Deklarationen der globalen Variablen und Stacks
 */
private void GenStackDeclarations() @safe
{
    if (optimizer.GlobalVar > 0 || optimizer.StackVar > 0)
    {
        for (int V = optimizer.firstGlobalVar; V <= optimizer.GlobalVar; ++V)
            WrSIS("HeapType GV", V, ";\n");
        for (int V = optimizer.firstStackVar; V <= optimizer.StackVar; ++V)
            WrSIS("Stacks.Stack Stack", V, ";\n");
        WrS("\n");
    }
}

/**
 * SEM: Generierung der Initialisierungen der Stacks
 */
private void GenStackInit() @safe
{
    if (optimizer.StackVar > 0)
    {
        for (int S = optimizer.firstStackVar; S <= optimizer.StackVar; ++S)
            WrSIS("Stacks.New(Stack", S, ", 8);\n");
    }
}

/**
 * SEM: Generierung des Compiler-Moduls
 */
private string GenerateModule(Settings settings)
{
    int R;
    Input Fix;
    int StartRule;

    void InclFix(char Term)
    {
        import std.conv : to;
        import std.exception : enforce;

        char c = Fix.front.to!char;

        while (c != Term)
        {
            enforce(c != 0,
                    "error: unexpected end of eSOAG.fix.d");

            Out.write(c);
            Fix.popFront;
            c = Fix.front.to!char;
        }
        Fix.popFront;
    }

    const name = EAG.BaseName ~ "Eval";
    const fileName = settings.path(name ~ ".d");

    Fix = read("fix/epsilon/soag.fix.d");
    Out = File(fileName, "w");
    SLEAGGen.InitGen(Out, SLEAGGen.sSweepPass, settings);
    InclFix('$');
    WrS(name);
    InclFix('$');
    WrI(HyperArity());
    InclFix('$');
    GenConstDeclarations;
    InclFix('$');
    if (Optimize)
        GenStackDeclarations;
    SLEAGGen.GenDeclarations(settings);
    InclFix('$');
    SLEAGGen.GenPredProcs;
    for (R = SOAG.firstRule; R < SOAG.NextRule; ++R)
    {
        if (SOAG.IsEvaluatorRule(R))
        {
            ComputeNodeNames(R);
            ComputeAffixOffset(R);
            GenVisitRule(R);
        }
    }
    GenVisit;
    EmitGen.GenEmitProc(Out, settings);
    InclFix('$');
    WrI(SOAG.NextPartNum);
    InclFix('$');
    if (Optimize)
        GenStackInit;
    StartRule = FirstRule[SOAG.SymOcc[SOAG.Sym[EAG.StartSym].FirstOcc].RuleInd];
    InclFix('$');
    if (StartRule - 1 != 0)
        WrIS(StartRule - 1, " + ");
    InclFix('$');
    WrSI("S", EAG.StartSym);
    InclFix('$');
    EmitGen.GenEmitCall(Out, settings);
    InclFix('$');
    EmitGen.GenShowHeap(Out);
    InclFix('$');
    if (Optimize)
        WrI(optimizer.StackVar);
    else
        WrI(0);
    InclFix('$');
    if (Optimize)
        WrI(optimizer.GlobalVar);
    else
        WrI(0);
    InclFix('$');
    WrS(EAG.BaseName);
    WrS("Eval");
    InclFix('$');
    Out.flush;
    SLEAGGen.FinitGen;
    Out.close;
    return fileName;
}
