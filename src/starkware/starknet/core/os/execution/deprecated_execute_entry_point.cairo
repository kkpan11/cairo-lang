from starkware.cairo.builtin_selection.select_builtins import select_builtins
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.find_element import find_element, search_sorted_optimistic
from starkware.cairo.common.math import assert_not_zero
from starkware.cairo.common.registers import get_ap
from starkware.starknet.core.os.block_context import BlockContext
from starkware.starknet.core.os.builtins import (
    BuiltinEncodings,
    BuiltinParams,
    BuiltinPointers,
    update_builtin_ptrs,
)
from starkware.starknet.core.os.constants import (
    DEFAULT_ENTRY_POINT_SELECTOR,
    DEFAULT_INITIAL_GAS_COST,
    ENTRY_POINT_TYPE_CONSTRUCTOR,
    ENTRY_POINT_TYPE_EXTERNAL,
    ENTRY_POINT_TYPE_L1_HANDLER,
    ERROR_ENTRY_POINT_NOT_FOUND,
    NOP_ENTRY_POINT_OFFSET,
)
from starkware.starknet.core.os.contract_class.deprecated_compiled_class import (
    DeprecatedCompiledClass,
    DeprecatedCompiledClassFact,
    DeprecatedContractEntryPoint,
)
from starkware.starknet.core.os.execution.execute_entry_point import (
    ExecutionContext,
    execute_entry_point,
)
from starkware.starknet.core.os.execution.revert import RevertLogEntry, init_revert_log
from starkware.starknet.core.os.output import OsCarriedOutputs

// Returns the entry point's offset in the program based on 'compiled_class' and
// 'execution_context'.
func get_entry_point_offset{range_check_ptr}(
    compiled_class: DeprecatedCompiledClass*, execution_context: ExecutionContext*
) -> (success: felt, entry_point_offset: felt) {
    alloc_locals;
    // Get the entry points corresponding to the transaction's type.
    local entry_points: DeprecatedContractEntryPoint*;
    local n_entry_points: felt;

    tempvar entry_point_type = execution_context.entry_point_type;
    if (entry_point_type == ENTRY_POINT_TYPE_L1_HANDLER) {
        entry_points = compiled_class.l1_handlers;
        n_entry_points = compiled_class.n_l1_handlers;
    } else {
        if (entry_point_type == ENTRY_POINT_TYPE_EXTERNAL) {
            entry_points = compiled_class.external_functions;
            n_entry_points = compiled_class.n_external_functions;
        } else {
            assert entry_point_type = ENTRY_POINT_TYPE_CONSTRUCTOR;
            entry_points = compiled_class.constructors;
            n_entry_points = compiled_class.n_constructors;

            if (n_entry_points == 0) {
                return (success=1, entry_point_offset=NOP_ENTRY_POINT_OFFSET);
            }
        }
    }

    // The key must be at offset 0.
    static_assert DeprecatedContractEntryPoint.selector == 0;
    let (entry_point_desc: DeprecatedContractEntryPoint*, success) = search_sorted_optimistic(
        array_ptr=cast(entry_points, felt*),
        elm_size=DeprecatedContractEntryPoint.SIZE,
        n_elms=n_entry_points,
        key=execution_context.execution_info.selector,
    );
    if (success != FALSE) {
        return (success=1, entry_point_offset=entry_point_desc.offset);
    }

    // If the selector was not found, check if we have a default entry point.
    if (n_entry_points != 0 and entry_points[0].selector == DEFAULT_ENTRY_POINT_SELECTOR) {
        return (success=1, entry_point_offset=entry_points[0].offset);
    }
    return (success=0, entry_point_offset=0);
}

// Performs a Cairo jump to the function 'execute_deprecated_syscalls'.
// This function's signature must match the signature of 'execute_deprecated_syscalls'.
func call_execute_deprecated_syscalls{
    range_check_ptr,
    builtin_ptrs: BuiltinPointers*,
    contract_state_changes: DictAccess*,
    contract_class_changes: DictAccess*,
    revert_log: RevertLogEntry*,
    outputs: OsCarriedOutputs*,
}(
    block_context: BlockContext*,
    execution_context: ExecutionContext*,
    syscall_size,
    syscall_ptr: felt*,
) {
    jmp abs block_context.execute_deprecated_syscalls_ptr;
}

// Executes an entry point in a contract.
// The contract entry point is selected based on execution_context.entry_point_type
// and execution_context.execution_info.selector.
//
// Arguments:
// block_context - a global context that is fixed throughout the block.
// execution_context - The context for the current execution.
func deprecated_execute_entry_point{
    range_check_ptr,
    builtin_ptrs: BuiltinPointers*,
    contract_state_changes: DictAccess*,
    contract_class_changes: DictAccess*,
    revert_log: RevertLogEntry*,
    outputs: OsCarriedOutputs*,
}(block_context: BlockContext*, execution_context: ExecutionContext*) -> (
    is_reverted: felt, retdata_size: felt, retdata: felt*
) {
    alloc_locals;

    // The key must be at offset 0.
    static_assert DeprecatedCompiledClassFact.hash == 0;
    let (compiled_class_fact: DeprecatedCompiledClassFact*) = find_element(
        array_ptr=block_context.deprecated_compiled_class_facts,
        elm_size=DeprecatedCompiledClassFact.SIZE,
        n_elms=block_context.n_deprecated_compiled_class_facts,
        key=execution_context.class_hash,
    );
    local compiled_class: DeprecatedCompiledClass* = compiled_class_fact.compiled_class;

    let (success, entry_point_offset) = get_entry_point_offset(
        compiled_class=compiled_class, execution_context=execution_context
    );

    if (success == 0) {
        %{ execution_helper.exit_call() %}
        let (retdata: felt*) = alloc();
        assert retdata[0] = ERROR_ENTRY_POINT_NOT_FOUND;
        return (is_reverted=1, retdata_size=1, retdata=retdata);
    }

    if (entry_point_offset == NOP_ENTRY_POINT_OFFSET) {
        %{ execution_helper.exit_call() %}
        // Assert that there is no call data in the case of NOP entry point.
        assert execution_context.calldata_size = 0;
        return (is_reverted=0, retdata_size=0, retdata=cast(0, felt*));
    }

    local range_check_ptr = range_check_ptr;
    local contract_entry_point: felt* = compiled_class.bytecode_ptr + entry_point_offset;

    let (local os_context: felt*) = alloc();
    let (local syscall_ptr: felt*) = alloc();

    assert [os_context] = cast(syscall_ptr, felt);

    let n_builtins = BuiltinEncodings.SIZE;
    local builtin_params: BuiltinParams* = block_context.builtin_params;
    select_builtins(
        n_builtins=n_builtins,
        all_encodings=builtin_params.builtin_encodings,
        all_ptrs=builtin_ptrs,
        n_selected_builtins=compiled_class.n_builtins,
        selected_encodings=compiled_class.builtin_list,
        selected_ptrs=os_context + 1,
    );

    // Use tempvar to pass arguments to contract_entry_point().
    tempvar selector = execution_context.execution_info.selector;
    tempvar context = os_context;
    tempvar calldata_size = execution_context.calldata_size;
    tempvar calldata = execution_context.calldata;

    %{ vm_enter_scope({'syscall_handler': deprecated_syscall_handler}) %}
    call abs contract_entry_point;
    %{ vm_exit_scope() %}
    %{ execution_helper.exit_call() %}

    // Retrieve returned_builtin_ptrs_subset.
    // Note that returned_builtin_ptrs_subset cannot be set in a hint because doing so will allow a
    // malicious prover to lie about the storage changes of a valid contract.
    let (ap_val) = get_ap();
    local returned_builtin_ptrs_subset: felt* = cast(ap_val - compiled_class.n_builtins - 2, felt*);
    local retdata_size: felt = [ap_val - 2];
    local retdata: felt* = cast([ap_val - 1], felt*);

    let return_builtin_ptrs = update_builtin_ptrs(
        builtin_params=builtin_params,
        builtin_ptrs=builtin_ptrs,
        n_selected_builtins=compiled_class.n_builtins,
        selected_encodings=compiled_class.builtin_list,
        selected_ptrs=returned_builtin_ptrs_subset,
    );

    // Validate that segment_arena builtin was not used.
    assert builtin_ptrs.selectable.segment_arena = return_builtin_ptrs.selectable.segment_arena;

    let syscall_end = cast([returned_builtin_ptrs_subset - 1], felt*);

    let builtin_ptrs = return_builtin_ptrs;
    call_execute_deprecated_syscalls(
        block_context=block_context,
        execution_context=execution_context,
        syscall_size=syscall_end - syscall_ptr,
        syscall_ptr=syscall_ptr,
    );

    return (is_reverted=0, retdata_size=retdata_size, retdata=retdata);
}

// Selects execute_entry_point function according to the Cairo version of the entry point.
func select_execute_entry_point_func{
    range_check_ptr,
    remaining_gas: felt,
    builtin_ptrs: BuiltinPointers*,
    contract_state_changes: DictAccess*,
    contract_class_changes: DictAccess*,
    revert_log: RevertLogEntry*,
    outputs: OsCarriedOutputs*,
}(block_context: BlockContext*, execution_context: ExecutionContext*) -> (
    is_reverted: felt, retdata_size: felt, retdata: felt*, is_deprecated: felt
) {
    alloc_locals;
    %{
        execution_helper.enter_call(
            cairo_execution_info=ids.execution_context.execution_info,
            deprecated_tx_info=ids.execution_context.deprecated_tx_info,
        )
    %}

    %{ is_deprecated = 1 if ids.execution_context.class_hash in __deprecated_class_hashes else 0 %}
    // Note that the class_hash is validated in both the `if` and `else` cases, so a malicious
    // prover won't be able to produce a proof if guesses the wrong case.
    if (nondet %{ is_deprecated %} != FALSE) {
        let (is_reverted, retdata_size, retdata: felt*) = deprecated_execute_entry_point(
            block_context=block_context, execution_context=execution_context
        );
        return (
            is_reverted=is_reverted, retdata_size=retdata_size, retdata=retdata, is_deprecated=1
        );
    }

    local caller_remaining_gas = remaining_gas;
    local is_sierra_gas_mode;
    %{ ids.is_sierra_gas_mode = execution_helper.call_info.tracked_resource.is_sierra_gas() %}
    if (is_sierra_gas_mode != FALSE) {
        tempvar remaining_gas = remaining_gas;
    } else {
        // Run with high enough gas to avoid out-of-gas.
        tempvar remaining_gas = DEFAULT_INITIAL_GAS_COST;
    }
    %{
        if execution_helper.debug_mode:
            expected_initial_gas = execution_helper.call_info.call.initial_gas
            call_initial_gas = ids.remaining_gas
            assert expected_initial_gas == call_initial_gas, (
                f"Expected remaining_gas {expected_initial_gas}. Got: {call_initial_gas}.\n"
                f"{execution_helper.call_info=}"
            )
    %}

    let (is_reverted, retdata_size, retdata) = execute_entry_point(
        block_context=block_context, execution_context=execution_context
    );

    if (is_sierra_gas_mode != FALSE) {
        tempvar remaining_gas = remaining_gas;
    } else {
        // Do not count Sierra gas for the caller in this case.
        tempvar remaining_gas = caller_remaining_gas;
    }
    return (is_reverted=is_reverted, retdata_size=retdata_size, retdata=retdata, is_deprecated=0);
}

// Same as `select_execute_entry_point_func`, but does not support reverts and does
// not have an implicit 'revert_log' argument.
func non_reverting_select_execute_entry_point_func{
    range_check_ptr,
    remaining_gas: felt,
    builtin_ptrs: BuiltinPointers*,
    contract_state_changes: DictAccess*,
    contract_class_changes: DictAccess*,
    outputs: OsCarriedOutputs*,
}(block_context: BlockContext*, execution_context: ExecutionContext*) -> (
    retdata_size: felt, retdata: felt*, is_deprecated: felt
) {
    let revert_log = init_revert_log();
    let (is_reverted, retdata_size, retdata, is_deprecated) = select_execute_entry_point_func{
        revert_log=revert_log
    }(block_context=block_context, execution_context=execution_context);
    assert is_reverted = 0;
    return (retdata_size, retdata, is_deprecated);
}
