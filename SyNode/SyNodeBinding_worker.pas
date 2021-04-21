/// `worker` module support bindings for SyNode
// - this unit is a part of the freeware Synopse framework,
// licensed under a MPL/GPL/LGPL tri-license; version 1.18
unit SyNodeBinding_worker;

interface
{$I SyNode.inc}

uses
  SynCommons,
  Classes,
  SpiderMonkey;

type
  TJSWorkersManager = class
  private
    FPool: TObjectListLocked;
    FWorkerCounter: integer;
    FIsInDestroyState: Boolean;
    function getCurrentWorkerThreadIndex: integer;
    function getCurrentWorkerID: integer;
    function getWorkerThreadIndexByID(aWorkerID: Integer): integer;
    function GetDoInteruptInOwnThreadhandlerForCurThread: TThreadMethod;
  public
    constructor Create;
    destructor Destroy; override;
    function Add(cx: PJSContext; const workerName: RawUTF8; const script: SynUnicode): Integer;
    function curThreadIsWorker: Boolean;
    function getCurrentWorkerThreadName: RawUTF8;
    procedure EnqueueOutMessageToCurrentThread(const mess: RawUTF8);
    function DequeueOutMessageFromThread(aWorkerID: Integer; out mess: RawUTF8): Boolean;
    procedure EnqueueInMessageToThread(const mess: RawUTF8; aWorkerID: Integer);
    function DequeueInMessageFromCurrentThread(out mess: RawUTF8): Boolean;
    procedure TerminateThread(aWorkerID: Integer; aNeedCancelExecution: Boolean = false);
    property DoInteruptInOwnThreadhandlerForCurThread: TThreadMethod read GetDoInteruptInOwnThreadhandlerForCurThread;
  end;

implementation

uses
  SyNode,
{$IFDEF MSWINDOWS}
  Windows,
{$ENDIF}
  SysUtils;

type
  TJSWorkerThread = class(TThread)
  private
    FEng: TSMEngine;
    fSMManager: TSMEngineManager;
    fModuleObj: PJSRootedObject;
    FNeedCallInterrupt: boolean;
    fInMessages: TRawUTF8List;
    fOutMessages: TRawUTF8List;
    FWorkerID: Integer;
    FName: RawUTF8;
    FScript: SynUnicode;
  protected
    procedure Execute; override;
    procedure doInteruptInOwnThread;
  public
    constructor Create(aSMManager: TSMEngineManager; workerName: RawUTF8; script: SynUnicode);
    destructor Destroy; override;
  end;

constructor TJSWorkerThread.Create(aSMManager: TSMEngineManager; workerName: RawUTF8; script: SynUnicode);
begin
  inherited Create(true);
  fSMManager := aSMManager;
  FWorkerID := InterlockedIncrement(fSMManager.WorkersManager.FWorkerCounter);
  FName := workerName;
  FScript := script;
  fInMessages := TRawUTF8List.Create();
  fOutMessages := TRawUTF8List.Create();
  FEng := nil;
  Suspended := False;
end;

destructor TJSWorkerThread.Destroy;
begin
  FreeAndNil(fInMessages);
  FreeAndNil(fOutMessages);
  if not Terminated then begin
    if FEng.cx.IsRunning then
      FEng.CancelExecution(false);
  end;
  inherited;
end;

procedure TJSWorkerThread.doInteruptInOwnThread;
begin
  FNeedCallInterrupt := true;
  Suspended := false;
end;

/// Post message from worker thread. aviable only in worker thread
function fromWorker_postMessage(cx: PJSContext; argc: uintN; var vp: jsargRec): Boolean; cdecl;
var
  in_argv: PjsvalVector;
  mes: RawUTF8;
const
  sInvalidCall = 'usage: postMessage(message: *)';
begin
  try
    in_argv := vp.argv;
    if (argc <> 1) then
      raise ESMException.Create(sInvalidCall);
    mes := in_argv[0].asJson[cx];
    TSMEngine(cx.PrivateData).Manager.WorkersManager.EnqueueOutMessageToCurrentThread(mes);
    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      vp.rval := JSVAL_VOID;
      JSError(cx, E);
    end;
  end;
end;

/// Terminate worker from thread. aviable only in worker thread
function fromWorker_terminate(cx: PJSContext; argc: uintN; var vp: jsargRec): Boolean; cdecl;
var
  fManager: TJSWorkersManager;
begin
  try
    fManager := TSMEngine(cx.PrivateData).Manager.WorkersManager;
    fManager.TerminateThread(fManager.getCurrentWorkerID);
    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      vp.rval := JSVAL_VOID;
      JSError(cx, E);
    end;
  end;
end;


procedure TJSWorkerThread.Execute;
var
  isEmpty: Boolean;
  mess: RawUTF8;
  val, rval: jsval;
  cx: PJSContext;
  msg, exc: PJSRootedValue;
begin
  FNeedCallInterrupt := false;
  FEng := fSMManager.ThreadSafeEngine(nil, 1{SM_ENGINE_TYPE_WORKER});
  try
    cx := FEng.cx;

    FEng.GlobalObject.ptr.DefineFunction(cx, 'postMessage', fromWorker_postMessage, 1, JSPROPS_STATIC_RO);
    FEng.GlobalObject.ptr.DefineFunction(cx, 'terminate', fromWorker_terminate, 0, JSPROPS_STATIC_RO);

    // define threadID in global for debugger
    //val.{$IFDEF CPU64}asInt64{$ELSE}asInteger{$ENDIF} := ThreadID;
    //FEng.GlobalObject.ptr.defineProperty(cx, 'threadID', val);
    try
      FEng.Evaluate(FScript, '<initialization>', 0, rval);
      if rval.isObject then
        fModuleObj := cx.NewRootedObject(rval.asObject)
      else begin
        Terminate;
        exit;
      end;
    except
      Terminate;
      exit;
    end;

    while not Terminated do begin
      if FNeedCallInterrupt then begin
        FEng.cx.RequestInterruptCallback;
        FEng.cx.CheckForInterrupt;
        FNeedCallInterrupt := false;
      end;

      isEmpty := fSMManager.WorkersManager.FIsInDestroyState
        or not fSMManager.WorkersManager.DequeueInMessageFromCurrentThread(mess);

      if not isEmpty then begin
        val.asJson[cx] := mess;
        msg := cx.NewRootedValue(val);
        try
          try
            if not Terminated then begin
              FEng.CallObjectFunction(fModuleObj, 'onmessage', [msg.ptr]);
            end;
          except
            if not (JS_IsExceptionPending(cx) and JS_GetPendingException(cx, val)) then begin
              val.setVoid;
            end;
            exc := cx.NewRootedValue(val);
            try
              if not fSMManager.WorkersManager.FIsInDestroyState and not exc.ptr.isVoid then begin
                try
                  FEng.CallObjectFunction(fModuleObj, 'onerror', [msg.ptr, exc.ptr]);
                except
                end;
              end;
            finally
              cx.FreeRootedValue(exc);
            end;
          end;
        finally
          cx.FreeRootedValue(msg);
        end;
      end else if not Terminated and not FNeedCallInterrupt then
        Suspended := True;
    end;
    try
      if not fSMManager.WorkersManager.FIsInDestroyState
        and fModuleObj.ptr.HasProperty(cx, 'onterminate') then
          FEng.CallObjectFunction(fModuleObj, 'onterminate', []);
    except
      ;
    end;
  finally
    if fModuleObj <> nil then
      cx.FreeRootedObject(fModuleObj);
    fSMManager.ReleaseCurrentThreadEngine;
    FEng := nil;
  end;

end;

{ TJSWorkersManager }

function TJSWorkersManager.Add(cx: PJSContext; const workerName: RawUTF8; const script: SynUnicode): Integer;
var
  wThread: TJSWorkerThread;
  i: Integer;
begin
  FPool.Safe.Lock;
  try
    // delete unused threads
    for i := FPool.Count - 1 downto 0 do begin
      wThread := TJSWorkerThread(FPool[i]);
      if wThread.Terminated and
        (wThread.fOutMessages.Count = 0) then
        FPool.Delete(i);
    end;
    wThread := TJSWorkerThread.Create(TSMEngine(cx.PrivateData).Manager, workerName, script);
    FPool.Add(wThread);
    Result := wThread.FWorkerID;
  finally
    FPool.Safe.UnLock;
  end;
end;

constructor TJSWorkersManager.Create;
begin
  FWorkerCounter := 0;
  FIsInDestroyState := false;
  FPool := TObjectListLocked.Create();
end;

function TJSWorkersManager.curThreadIsWorker: Boolean;
begin
  FPool.Safe.Lock;
  try
    Result := getCurrentWorkerThreadIndex <> -1;
  finally
    FPool.Safe.UnLock;
  end;
end;

function TJSWorkersManager.DequeueInMessageFromCurrentThread(out mess: RawUTF8): Boolean;
var
  curThreadIndex: Integer;
begin
  Result := false;
  FPool.Safe.Lock;
  try
    curThreadIndex := getCurrentWorkerThreadIndex;
    if curThreadIndex <> -1 then begin
      Result := TJSWorkerThread(FPool[curThreadIndex]).fInMessages.PopFirst(mess);
    end;
  finally
    FPool.Safe.UnLock;
  end;
end;

function TJSWorkersManager.DequeueOutMessageFromThread(aWorkerID: Integer;
  out mess: RawUTF8): Boolean;
var
  ThreadIndex: Integer;
  wThread: TJSWorkerThread;
begin
  Result := false;
  FPool.Safe.Lock;
  try
    ThreadIndex := getWorkerThreadIndexByID(aWorkerID);
    if ThreadIndex <> -1 then begin
      wThread := TJSWorkerThread(FPool[ThreadIndex]);
      Result := wThread.fOutMessages.PopFirst(mess);
      if wThread.Terminated and (wThread.fOutMessages.Count = 0) then
        FPool.Delete(ThreadIndex);
    end;
  finally
    FPool.Safe.UnLock;
  end;
end;

destructor TJSWorkersManager.Destroy;
var i: Integer;
begin
  FIsInDestroyState := True;
  FPool.Safe.Lock;
  try
    for i := 0 to FPool.Count - 1 do begin
      TerminateThread(TJSWorkerThread(FPool[i]).FWorkerID, True);
    end;
  finally
    FPool.Safe.UnLock;
  end;
  FreeAndNil(FPool);
  inherited;
end;

procedure TJSWorkersManager.EnqueueInMessageToThread(const mess: RawUTF8;
  aWorkerID: Integer);
var
  ThreadIndex: Integer;
  thread: TJSWorkerThread;
begin
  FPool.Safe.Lock;
  try
    ThreadIndex := getWorkerThreadIndexByID(aWorkerID);
    if ThreadIndex <> -1 then begin
      thread := TJSWorkerThread(FPool[ThreadIndex]);
      if not thread.Terminated then begin
        thread.fInMessages.Add(mess);
        thread.Suspended := False;
      end;
    end;
  finally
    FPool.Safe.UnLock;
  end;
end;

procedure TJSWorkersManager.EnqueueOutMessageToCurrentThread(
  const mess: RawUTF8);
var
  curThreadIndex: Integer;
begin
  FPool.Safe.Lock;
  try
    curThreadIndex := getCurrentWorkerThreadIndex;
    if curThreadIndex <> -1 then begin
      TJSWorkerThread(FPool[curThreadIndex]).fOutMessages.Add(mess);
    end;
  finally
    FPool.Safe.UnLock;
  end;
end;

function TJSWorkersManager.getCurrentWorkerID: integer;
var
  i: Integer;
  curThreadID: TThreadID;
begin
  Result := -1;
  curThreadID := GetCurrentThreadId;
  for i := 0 to FPool.Count - 1 do begin
    if TJSWorkerThread(FPool[i]).ThreadID = curThreadID then begin
      Result := TJSWorkerThread(FPool[i]).FWorkerID;
      Exit;
    end;
  end;
end;

function TJSWorkersManager.getCurrentWorkerThreadIndex: integer;
var
  i: Integer;
  curThreadID: TThreadID;
begin
  Result := -1;
  curThreadID := GetCurrentThreadId;
  for i := 0 to FPool.Count - 1 do begin
    if TJSWorkerThread(FPool[i]).ThreadID = curThreadID then begin
      Result := i;
      Exit;
    end;
  end;
end;

function TJSWorkersManager.getCurrentWorkerThreadName: RawUTF8;
var
  curThreadIndex: Integer;
begin
  Result := '';
  FPool.Safe.Lock;
  try
    curThreadIndex := getCurrentWorkerThreadIndex;
    if curThreadIndex <> -1 then
      Result := TJSWorkerThread(FPool[curThreadIndex]).FName;
  finally
    FPool.Safe.UnLock;
  end;
end;

function TJSWorkersManager.getWorkerThreadIndexByID(aWorkerID: Integer): integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to FPool.Count - 1 do begin
    if TJSWorkerThread(FPool[i]).FWorkerID = aWorkerID then begin
      Result := i;
      Exit;
    end;
  end;
end;

function TJSWorkersManager.GetDoInteruptInOwnThreadhandlerForCurThread: TThreadMethod;
var
  curThreadIndex: Integer;
begin
  Result := nil;
  FPool.Safe.Lock;
  try
    curThreadIndex := getCurrentWorkerThreadIndex;
    if curThreadIndex <> -1 then
      Result := TJSWorkerThread(FPool[curThreadIndex]).doInteruptInOwnThread;
  finally
    FPool.Safe.UnLock;
  end;
end;

procedure TJSWorkersManager.TerminateThread(aWorkerID: Integer; aNeedCancelExecution: Boolean = false);
var
  ThreadIndex: Integer;
  thread: TJSWorkerThread;
begin
  FPool.Safe.Lock;
  try
    ThreadIndex := getWorkerThreadIndexByID(aWorkerID);
    if ThreadIndex <> -1 then begin
      thread := TJSWorkerThread(FPool[ThreadIndex]);
      if aNeedCancelExecution and (thread.FEng <> nil) then
        thread.FEng.CancelExecution(False);
      thread.Terminate;
      thread.Suspended := False;
    end;
  finally
    FPool.Safe.UnLock;
  end;
end;

/// create new worker thread. return worker ID
// new thread require module. Module must export 3 function:
// - onmessage
// - onterminate
// - onerror
function worker_createThread(cx: PJSContext; argc: uintN; var vp: jsargRec): Boolean; cdecl;
var
  in_argv: PjsvalVector;
  moduleStr: SynUnicode;
  workerName: RawUTF8;
  params: PJSObject;
  IsInvalidCall: Boolean;
  name, module: jsval;
  val: jsval;
  FEng: TSMEngine;
const
  sInvalidCall = 'usage: createThread({name: String, moduleName: string[, message: *]})';
begin
  try
    in_argv := vp.argv;

    IsInvalidCall := (argc < 1) and in_argv[0].isObject;
    if not IsInvalidCall then begin
      params := in_argv[0].asObject;

      params.GetProperty(cx, 'name', name);
      if name.isString then
        workerName := name.asJSString.ToUTF8(cx)
      else
        IsInvalidCall := True;

      if not IsInvalidCall then begin
        params.GetProperty(cx, 'moduleName', module);
        if not module.isString then
          IsInvalidCall := True
        else
          moduleStr := module.asJSString.ToSynUnicode(cx)
      end;
    end;
    if IsInvalidCall then
      raise ESMException.Create(sInvalidCall);

    FEng := TSMEngine(cx.PrivateData);
    val.asInteger := FEng.Manager.WorkersManager.Add(cx, workerName,
      'require("' + moduleStr + '")');
    vp.rval := val;
    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      vp.rval := JSVAL_VOID;
      JSError(cx, E);
    end;
  end;
end;

/// Post message to worker thread
function worker_postMessage(cx: PJSContext; argc: uintN; var vp: jsargRec): Boolean; cdecl;
var
  in_argv: PjsvalVector;
  workerID: integer;
  mes: RawUTF8;
const
  sInvalidCall = 'usage: postMessage(threadID: Number, message: String);';
begin
  try
    in_argv := vp.argv;
    if (argc < 2) or not (in_argv[0].isNumber) or not (in_argv[1].isString) then
      raise ESMException.Create(sInvalidCall);
    workerID := in_argv[0].asInteger;

    mes := in_argv[1].asJSString.ToUTF8(cx);
    TSMEngine(cx.PrivateData).Manager.WorkersManager.EnqueueInMessageToThread(mes, workerID);

    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      vp.rval := JSVAL_VOID;
      JSError(cx, E);
    end;
  end;

end;

/// Get message from worker thread
function  worker_getMessage(cx: PJSContext; argc: uintN; var vp: jsargRec): Boolean; cdecl;
var
  in_argv: PjsvalVector;
  workerID: Integer;
  mes: RawUTF8;
const
  sInvalidCall = 'usage: getMessage(threadID: Number);';
begin
  try
    in_argv := vp.argv;
    if (argc < 1) or not (in_argv[0].isNumber) then
      raise ESMException.Create(sInvalidCall);

    if in_argv[0].isInteger then
      workerID := in_argv[0].asInteger
    else
      workerID := Round(in_argv[0].asDouble);

    if TSMEngine(cx.PrivateData).Manager.WorkersManager.DequeueOutMessageFromThread(workerID, mes) then
      vp.rval := cx.NewJSString(mes).ToJSVal
    else
      vp.rval := JSVAL_VOID;

    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      vp.rval := JSVAL_VOID;
      JSError(cx, E);
    end;
  end;
end;

/// Terminate worker thread.
function worker_terminate(cx: PJSContext; argc: uintN; var vp: jsargRec): Boolean; cdecl;
var
  in_argv: PjsvalVector;
  threadID: Integer;
const
  sInvalidCall = 'usage: terminate(threadID: Number);';
begin
  try
    in_argv := vp.argv;
    if (argc < 1) or not (in_argv[0].isNumber) then
      raise ESMException.Create(sInvalidCall);

    if in_argv[0].isInteger then
      threadID := in_argv[0].asInteger
    else
      threadID := Round(in_argv[0].asDouble);

    TSMEngine(cx.PrivateData).Manager.WorkersManager.TerminateThread(threadID, true);

    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      vp.rval := JSVAL_VOID;
      JSError(cx, E);
    end;
  end;
end;

function SyNodeBindingProc_worker(const aEngine: TSMEngine; const bindingNamespaceName: SynUnicode): jsval;
var
  obj: PJSRootedObject;
  cx: PJSContext;
const
  props = JSPROP_ENUMERATE or JSPROP_ENUMERATE or JSPROP_PERMANENT;
begin
  cx := aEngine.cx;
  obj := cx.NewRootedObject(cx.NewObject(nil));
  obj.ptr.DefineFunction(cx, 'createThread', worker_createThread, 1, props);
  obj.ptr.DefineFunction(cx, 'postMessage', worker_postMessage, 2, props);
  obj.ptr.DefineFunction(cx, 'getMessage', worker_getMessage, 1, props);
  obj.ptr.DefineFunction(cx, 'terminate', worker_terminate, 1, props);
  Result := obj.ptr.ToJSValue;
  cx.FreeRootedObject(obj);
end;

initialization
  TSMEngineManager.RegisterBinding('worker', SyNodeBindingProc_worker);
end.
