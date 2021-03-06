#=
Copyright (c) 2015, Intel Corporation
All rights reserved.

Redistribution and use in source and binary forms, with or without 
modification, are permitted provided that the following conditions are met:
- Redistributions of source code must retain the above copyright notice, 
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, 
  this list of conditions and the following disclaimer in the documentation 
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF 
THE POSSIBILITY OF SUCH DAMAGE.
=#

module CallGraph

import CompilerTools.DebugMsg
DebugMsg.init()

import Base.show
using CompilerTools.LambdaHandling
using CompilerTools.LivenessAnalysis

type CallInfo
  func_sig                             # a tuple of (function, signature)
  could_be_global :: Set               # the set of indices of arguments to the function that are or could be global arrays
  array_parameters :: Dict{Int,Any}    # the set of indices of arguments to the function that are or could be array parameters to the caller
end

type FunctionInfo
  func_sig                             # a tuple of (function, signature)
  calls :: Array{CallInfo,1}
  array_params_set_or_aliased :: Set   # the indices of the parameters that are set or aliased
  can_parallelize :: Bool              # false if a global is written in this function
  recursive_parallelize :: Bool
  lambdaInfo :: LambdaInfo
end

type extractStaticCallGraphState
  cur_func_sig
  mapNameFuncInfo :: Dict{Any,FunctionInfo}
  functionsToProcess :: Set

  calls :: Array{CallInfo,1}
  globalWrites :: Set
  lambdaInfo   :: Union{LambdaInfo, Void}
  array_params_set_or_aliased :: Set   # the indices of the parameters that are set or aliased
  cant_analyze :: Bool

  local_lambdas :: Dict{Symbol,LambdaStaticData}

  function extractStaticCallGraphState(fs, mnfi, ftp)
    new(fs, mnfi, ftp, CallInfo[], Set(), nothing, Set(), false, Dict{Symbol,LambdaStaticData}())
  end

  function extractStaticCallGraphState(fs, mnfi, ftp, calls, gw, ll)
    new(fs, mnfi, ftp, calls, gw, nothing, Set(), false, ll)
  end
end

function indexin(a, b::Array{Any,1})
  for i = 1:length(b)
    if b[i] == a
      return i
    end
  end
  throw(string("element not found in input array in indexin"))
end

function resolveFuncByName(cur_func_sig , func :: Symbol, call_sig_arg_tuple, local_lambdas)
  dprintln(4,"resolveFuncByName ", cur_func_sig, " ", func, " ", call_sig_arg_tuple, " ", local_lambdas)
  ftyp = typeof(cur_func_sig[1])
  if ftyp == Function
    cur_module = Base.function_module(cur_func_sig[1])
  elseif ftyp == LambdaStaticData
    cur_module = cur_func_sig[1].module
  else
    throw(string("Unsupported current function type in resolveFuncByName."))
  end
  dprintln(4,"Starting module = ", Base.module_name(cur_module))

  if haskey(local_lambdas, func)
    return local_lambdas[func]
  end

  while true
    if isdefined(cur_module, func)
      return getfield(cur_module, func)
    else
      if cur_module == Main
        break
      else
        cur_module = Base.module_parent(cur_module)
      end
    end
  end

  if isdefined(Base, func)
    return getfield(Base, func)
  end
  if isdefined(Main, func)
    return getfield(Main, func)
  end
  throw(string("Failed to resolve symbol ", func, " in ", Base.function_name(cur_func_sig[1])))
end

function isGlobal(sym :: Symbol, varDict :: Dict{Symbol,Array{Any,1}})
  return !haskey(varDict, sym)
end

function getGlobalOrArrayParam(varDict :: Dict{Symbol, Array{Any,1}}, params, real_args)
  possibleGlobalArgs = Set()
  possibleArrayArgs  = Dict{Int,Any}()

  dprintln(3,"getGlobalOrArrayParam ", real_args, " varDict ", varDict, " params ", params)
  for i = 1:length(real_args)
    atyp = typeof(real_args[i])
    dprintln(3,"getGlobalOrArrayParam arg ", i, " ", real_args[i], " type = ", atyp)
    if atyp == Symbol || atyp == SymbolNode
      aname = ParallelIR.getSName(real_args[i])
      if isGlobal(aname, varDict)
        # definitely a global so add
        push!(possibleGlobalArgs, i)
      elseif in(aname, params)
        possibleArrayArgs[i] = aname
      end
    else
      # unknown so add
      push!(possibleGlobalArgs, i)
      possibleArrayArgs[i] = nothing
    end
  end

  [possibleGlobalArgs, possibleArrayArgs]
end

function processFuncCall(state, func_expr, call_sig_arg_tuple, possibleGlobals, possibleArrayParams)
  fetyp = typeof(func_expr)

  dprintln(3,"processFuncCall ", func_expr, " ", call_sig_arg_tuple, " ", fetyp, " ", possibleGlobals)
  if fetyp == Symbol || fetyp == SymbolNode
    func = resolveFuncByName(state.cur_func_sig, ParallelIR.getSName(func_expr), call_sig_arg_tuple, state.local_lambdas)
  elseif fetyp == TopNode
    return nothing
  elseif fetyp == DataType
    return nothing
  elseif fetyp == GlobalRef
    func = getfield(func_expr.mod, func_expr.name)
  elseif fetyp == Expr
    dprintln(3,"head = ", func_expr.head)
    if func_expr.head == :call && func_expr.args[1] == TopNode(:getfield)
      dprintln(3,"args2 = ", func_expr.args[2], " type = ", typeof(func_expr.args[2]))
      dprintln(3,"args3 = ", func_expr.args[3], " type = ", typeof(func_expr.args[3]))
      fsym = func_expr.args[3]
      if typeof(fsym) == QuoteNode
        fsym = fsym.value
      end
      func = getfield(Main.(func_expr.args[2]), fsym)
    else
      func = eval(func_expr)
    end
    dprintln(3,"eval of func_expr is ", func, " type = ", typeof(func))
  else
    throw(string("Unhandled func expression type ", fetyp," for ", func_expr, " in ", Base.function_name(state.cur_func_sig.func)))
  end

  ftyp = typeof(func)
  dprintln(4,"After name resolution: func = ", func, " type = ", ftyp)
  if ftyp == DataType
    return nothing
  end
  assert(ftyp == Function || ftyp == IntrinsicFunction || ftyp == LambdaStaticData)

  if ftyp == Function
    fs = (func, call_sig_arg_tuple)

    if !haskey(state.mapNameFuncInfo, fs)
      dprintln(3,"Adding ", func, " to functionsToProcess")
      push!(state.functionsToProcess, fs)
      dprintln(3,state.functionsToProcess)
    end
    push!(state.calls, CallInfo(fs, possibleGlobals, possibleArrayParams))
  elseif ftyp == LambdaStaticData
    fs = (func, call_sig_arg_tuple)

    if !haskey(state.mapNameFuncInfo, fs)
      dprintln(3,"Adding ", func, " to functionsToProcess")
      push!(state.functionsToProcess, fs)
      dprintln(3,state.functionsToProcess)
    end
    push!(state.calls, CallInfo(fs, possibleGlobals, possibleArrayParams))
  end
end

function extractStaticCallGraphWalk(node, state :: extractStaticCallGraphState, top_level_number :: Int64, is_top_level :: Bool, read :: Bool)
  asttyp = typeof(node)
  dprintln(4,"escgw: ", node, " type = ", asttyp)
  if asttyp == Expr
    head = node.head
    args = node.args
    if head == :lambda
      if state.lambdaInfo == nothing
        state.lambdaInfo = lambdaExprToLambdaInfo(node)
        dprintln(3, "lambdaInfo = ", state.lambdaInfo)
      else
        new_lambda_state = extractStaticCallGraphState(state.cur_func_sig, state.mapNameFuncInfo, state.functionsToProcess, state.calls, state.globalWrites, state.local_lambdas)
        AstWalker.AstWalk(node, extractStaticCallGraphWalk, new_lambda_state)
        return node
      end
    elseif head == :call || head == :call1
      func_expr = args[1]
      call_args = args[2:end]
      call_sig = Expr(:tuple)
      call_sig.args = map(x -> typeOfOpr(state.lambdaInfo, x), call_args)
      call_sig_arg_tuple = eval(call_sig)
      dprintln(4,"func_expr = ", func_expr)
      dprintln(4,"Arg tuple = ", call_sig_arg_tuple)

      pmap_name = symbol("__pmap#39__")
      if func_expr == TopNode(pmap_name)
        func_expr = call_args[3]
        assert(typeof(func_expr) == SymbolNode)
        func_expr = func_expr.name
        call_sig = Expr(:tuple)
        push!(call_sig.args, ParallelIR.getArrayElemType(call_args[4]))
        call_sig_arg_tuple = eval(call_sig)
        dprintln(3,"Found pmap with func = ", func_expr, " and arg = ", call_sig_arg_tuple)
        processFuncCall(state, func_expr, call_sig_arg_tuple, getGlobalOrArrayParam(state.types, state.params, [call_args[4]])...)
        return node
      elseif func_expr == :map
        func_expr = call_args[1]
        call_sig = Expr(:tuple)
        push!(call_sig.args, ParallelIR.getArrayElemType(call_args[2]))
        call_sig_arg_tuple = eval(call_sig)
        dprintln(3,"Found map with func = ", func_expr, " and arg = ", call_sig_arg_tuple)
        processFuncCall(state, func_expr, call_sig_arg_tuple, getGlobalOrArrayParam(state.types, state.params, [call_args[2]])...)
        return node
      elseif func_expr == :broadcast!
        assert(length(call_args) == 4)
        func_expr = call_args[1]
        dprintln(3,"ca types = ", typeof(call_args[2]), " ", typeof(call_args[3]), " ", typeof(call_args[4]))
        catype = call_args[2].typ
        assert(call_args[3].typ == catype)
        assert(call_args[4].typ == catype)
        call_sig = Expr(:tuple)
        push!(call_sig.args, ParallelIR.getArrayElemType(catype))
        push!(call_sig.args, ParallelIR.getArrayElemType(catype))
        call_sig_arg_tuple = eval(call_sig)
        dprintln(3,"Found broadcast! with func = ", func_expr, " and arg = ", call_sig_arg_tuple)
        processFuncCall(state, func_expr, call_sig_arg_tuple, getGlobalOrArrayParam(state.types, state.params, call_args[2:4])...)
        return node
      elseif func_expr == :cartesianarray
        new_lambda_state = extractStaticCallGraphState(state.cur_func_sig, state.mapNameFuncInfo, state.functionsToProcess, state.calls, state.globalWrites, state.local_lambdas)
        AstWalker.AstWalk(call_args[1], extractStaticCallGraphWalk, new_lambda_state)
        for i = 2:length(call_args)
          AstWalker.AstWalk(call_args[i], extractStaticCallGraphWalk, state)
        end
        return node
      elseif ParallelIR.isArrayset(func_expr) || func_expr == :setindex!
        dprintln(3,"arrayset or setindex! found")
        array_name = call_args[1]
        if in(ParallelIR.getSName(array_name), state.params)
          dprintln(3,"can't analyze due to write to array")
          # Writing to an array parameter which could be a global passed to this function makes parallelization analysis unsafe.
          #state.cant_analyze = true
          push!(state.array_params_set_or_aliased, indexin(ParallelIR.getSName(array_name), state.params))
        end
        return node
      end

      processFuncCall(state, func_expr, call_sig_arg_tuple, getGlobalOrArrayParam(state.types, state.params, call_args)...)
    elseif head == :(=)
      lhs = args[1]
      rhs = args[2]
      rhstyp = typeof(rhs)
      dprintln(3,"Found assignment: lhs = ", lhs, " rhs = ", rhs, " type = ", typeof(rhs))
      if rhstyp == LambdaStaticData
        state.local_lambdas[lhs] = rhs
        return node
      elseif rhstyp == SymbolNode || rhstyp == Symbol
        rhsname = ParallelIR.getSName(rhs)
        if in(rhsname, state.params)
          rhsname_typ = state.types[rhsname][2]
          if rhsname_typ.name == Array.name
            # if an array parameter is the right-hand side of an assignment then we give up on tracking whether some parallelization requirement is violated for this parameter
            # state.cant_analyze = true
            push!(state.array_params_set_or_aliased, indexin(rhsname, state.params))
          end
        end
      end
    end
  elseif asttyp == Symbol
    dprintln(4,"Symbol ", node, " found in extractStaticCallGraphWalk. ", read, " ", isGlobal(node, state.types))
    if !read && isGlobal(node, state.types)
      dprintln(3,"Detected a global write to ", node, " ", state.types)
      push!(state.globalWrites, node)
    end
  elseif asttyp == SymbolNode
    dprintln(4,"SymbolNode ", node, " found in extractStaticCallGraphWalk.", read, " ", isGlobal(node.name, state.types))
    if !read && isGlobal(node.name, state.types)
      dprintln(3,"Detected a global write to ", node.name, " ", state.types)
      push!(state.globalWrites, node.name)
    end
    if node.typ == Function
      throw(string("Unhandled function in extractStaticCallGraphWalk."))
    end
  end

  # Don't make any changes to the AST, just record information in the state variable.
  return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function show(io::IO, cg :: Dict{Any,FunctionInfo})
  for i in cg
    println(io,"Function: ", i[2].func_sig[1], " ", i[2].func_sig[2], " local_par: ", i[2].can_parallelize, " recursive_par: ", i[2].recursive_parallelize, " array_params: ", i[2].array_params_set_or_aliased)
    for j in i[2].calls
      print(io,"    ", j)
      if haskey(cg, j.func_sig)
        jfi = cg[j.func_sig]
        print(io, " (", jfi.can_parallelize, ",", jfi.recursive_parallelize, ",", jfi.array_params_set_or_aliased, ")")
      end
      println(io,"")
    end
  end
end

function propagate(mapNameFuncInfo)
  # The can_parallelize field is purely local but the recursive_parallelize field includes all the children of this function.
  # Initialize the recursive state to the local state.
  for i in mapNameFuncInfo
    i[2].recursive_parallelize = i[2].can_parallelize
  end

  changes = true
  loop_iter = 1

  # Keep iterating so long as we find changes to a some recursive_parallelize field.
  while changes
    dprintln(3,"propagate ", loop_iter)
    loop_iter = loop_iter + 1

    changes = false
    # For each function in the call graph
    for i in mapNameFuncInfo  # i of type FunctionInfo
      this_fi = i[2]

      dprintln(3,"propagate for ", i)
      # If the function so far thinks it can parallelize.
      if this_fi.recursive_parallelize
        # Check everything it calls.
        for j in this_fi.calls # j of type CallInfo
          dprintln(3,"    call ", j)
          if haskey(mapNameFuncInfo, j.func_sig)
            dprintln(3,"    call ", j, " found")
            other_func = mapNameFuncInfo[j.func_sig]
            # If one of its callees can't be parallelized then it can't either.
            if !other_func.recursive_parallelize
              # Record we found a change so the outer iteration must continue.
              changes = true
              # Record that the current function can't parallelize.
              dprintln(3,"Function ", i[1], " not parallelizable since callee ", j.func_sig," isn't.")
              this_fi.recursive_parallelize = false
              break
            end
            if !isempty(intersect(j.could_be_global, other_func.array_params_set_or_aliased))
              # Record we found a change so the outer iteration must continue.
              changes = true
              # Record that the current function can't parallelize.
              dprintln(3,"Function ", i[1], " not parallelizable since callee ", j.func_sig," intersects at ", intersect(j.could_be_global, other_func.array_params_set_or_aliased))
              this_fi.recursive_parallelize = false
              break
            end
            for k in j.array_parameters
              dprintln(3,"    k = ", k)
              arg_index = k[1]
              arg_array_name = k[2]
              if in(arg_index, other_func.array_params_set_or_aliased)
                if typeof(arg_array_name) == Symbol
                  push!(this_fi.array_params_set_or_aliased, indexin(arg_array_name, this_fi.params))
                else
                  for l = 1:length(this_fi.params)
                    ptype = this_fi.types[this_fi.params[l]][2]
                    if ptype.name == Array.name
                      push!(this_fi.array_params_set_or_aliased, l)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end


function extractStaticCallGraph(func, sig)
  assert(typeof(func) == Function)

  functionsToProcess = Set()
  push!(functionsToProcess, (func,sig))

  mapNameFuncInfo = Dict{Any,FunctionInfo}()

  while length(functionsToProcess) > 0
    cur_func_sig = first(functionsToProcess)
    delete!(functionsToProcess, cur_func_sig)
    the_func = cur_func_sig[1]
    the_sig  = cur_func_sig[2]
    ftyp     = typeof(the_func)
    dprintln(3,"functionsToProcess left = ", functionsToProcess)

    if ftyp == Function
      dprintln(3,"Processing function ", the_func, " ", Base.function_name(the_func), " ", the_sig)

      method = methods(the_func, the_sig)
      if length(method) < 1
        dprintln(3,"Skipping function not found. ", the_func, " ", Base.function_name(the_func), " ", the_sig)
        continue
      end
      ct = code_typed(the_func, the_sig)
      dprintln(4,ct[1])
      state = extractStaticCallGraphState(cur_func_sig, mapNameFuncInfo, functionsToProcess)
      AstWalker.AstWalk(ct[1], extractStaticCallGraphWalk, state)
      dprintln(4,state)
      mapNameFuncInfo[cur_func_sig] = FunctionInfo(cur_func_sig, state.calls, state.array_params_set_or_aliased, !state.cant_analyze && length(state.globalWrites) == 0, true, state.lambdaInfo)
    elseif ftyp == LambdaStaticData
      dprintln(3,"Processing lambda static data ", the_func, " ", the_sig)
      ast = ParallelIR.uncompressed_ast(the_func)
      dprintln(4,ast)
      state = extractStaticCallGraphState(cur_func_sig, mapNameFuncInfo, functionsToProcess)
      AstWalker.AstWalk(ast, extractStaticCallGraphWalk, state)
      dprintln(4,state)
      mapNameFuncInfo[cur_func_sig] = FunctionInfo(cur_func_sig, state.calls, state.array_params_set_or_aliased, !state.cant_analyze && length(state.globalWrites) == 0, true, state.lambdaInfo)
    end
  end

  propagate(mapNameFuncInfo)
  mapNameFuncInfo
end


use_extract_static_call_graph = 0
function use_static_call_graph(x)
    global use_extract_static_call_graph = x
end

end
