#include <ATen/functorch/ADInterpreters.h>
#include <ATen/functorch/DynamicLayer.h>
#include <ATen/functorch/TensorWrapper.h>

namespace at { namespace functorch {

static void checkForInvalidMutationOnCaptures(
    const c10::OperatorHandle& op,
    const torch::jit::Stack* stack,
    int64_t cur_level) {
  if (!isInplaceOp(op.schema())) {
    return;
  }
  auto args = torch::jit::last(stack, op.schema().arguments().size());
  auto mutated_arg = unwrapIfDead(args[0].toTensor());
  auto* wrapper = maybeGetTensorWrapper(mutated_arg);
  if (wrapper && wrapper->level().has_value() && wrapper->level().value() == cur_level && !(wrapper->is_immutable())) {
    return;
  }
  TORCH_CHECK(false,
      "During a grad (vjp, jvp, grad, etc) transform, the function provided ",
      "attempted to call in-place operation (", op.schema().operator_name(), ") ",
      "that would mutate a captured Tensor. This is not supported; please rewrite ",
      "the function being transformed to explicitly accept the mutated Tensor(s) ",
      "as inputs.");
}

static Tensor materializeGradWrappers(const Tensor& tensor, int64_t current_level) {
  if (!tensor.defined()) {
    return tensor;
  }
  auto* wrapper = maybeGetTensorWrapper(tensor);
  if (!wrapper) {
    return makeTensorWrapper(tensor, current_level, true);
  }
  TORCH_INTERNAL_ASSERT(wrapper->level().value() <= current_level, "escaped?");
  if (wrapper->level().value() == current_level) {
    TORCH_INTERNAL_ASSERT(tensor.defined());
    return tensor;
  }
  return makeTensorWrapper(tensor, current_level, true);
}

static void autogradBasedTransformProcess(
    const c10::OperatorHandle& op,
    torch::jit::Stack* stack,
    int64_t current_level,
    TransformType transform_type) {
  // if is a grad transform, and the operation is in-place, and the mutated
  // argument is not currently wrapped in a TensorWrapper, then we need to
  // error out otherwise the result is silently incorrect
  checkForInvalidMutationOnCaptures(op, stack, current_level);

  // materialize live GradWrappers
  auto maybeTransformGradWrappers = [&](const Tensor& tensor) {
    return materializeGradWrappers(tensor, current_level);
  };
  auto num_args = op.schema().arguments().size();
  foreachTensorInplace(*stack, stack->size() - num_args, stack->size(), maybeTransformGradWrappers);

  auto exclude = keysToExcludeWhenEnteringDynamicLayer(transform_type);
  setup_dispatch_key_tls(exclude, {});
  op.callBoxed(stack);
}

static void autogradBasedTransformSendToNext(
    const c10::OperatorHandle& op,
    torch::jit::Stack* stack,
    int64_t current_level,
    TransformType transform_type,
    optional<bool> prev_grad_mode,
    optional<bool> prev_fwd_grad_mode,
    bool grad_special_case) {
  if (transform_type == TransformType::Grad) {
    TORCH_INTERNAL_ASSERT(prev_grad_mode.has_value());
  }
  if (transform_type == TransformType::Jvp) {
    TORCH_INTERNAL_ASSERT(prev_fwd_grad_mode.has_value());
  }
  auto unwrap = [&](const Tensor& tensor) {
    if (!tensor.defined()) {
      return tensor;
    }
    auto* maybe_tensor_wrapper = maybeGetTensorWrapper(tensor);
    if (!maybe_tensor_wrapper) {
      return tensor;
    }
    auto tensor_wrapper_level = maybe_tensor_wrapper->level().value();
    TORCH_INTERNAL_ASSERT(tensor_wrapper_level <= current_level);
    if (tensor_wrapper_level == current_level) {
      return maybe_tensor_wrapper->value();
    }
    return tensor;
  };
  auto wrap = [&](const Tensor& tensor, bool is_immutable) {
    if (!tensor.defined()) {
      return tensor;
    }
    // if (c10::show_dispatch_trace_enabled()) {
    //   std::cout << "wrap " << current_level << std::endl;
    // }
    return makeTensorWrapper(tensor, current_level, is_immutable);
  };

  // TODO: we only need to do the following (marked with !) on in-place functions
  // that modify sizes or strides. There aren't many of them.
  // If autograd dispatch key:
  // 1. (!) Put a copy of all of the args onto the stack
  // 2. Unwrap all the args in the copy set
  // 3. Call the operator
  // 4. Wrap the output
  // 5. (!) refreshMetadata for all the args in the original set
  // 6. (!) Pop those args off.

  // Step 1 & 2
  auto args_size = op.schema().arguments().size();
  // Step 1
  auto front = stack->size() - args_size;
  for (const auto arg_idx : c10::irange(0, args_size)) {
    stack->push_back((*stack)[front + arg_idx]);
  }

  std::vector<int64_t> immutable_inputs;  // all immutable inputs, sorted
  for (auto idx = stack->size() - args_size; idx < stack->size(); idx++) {
    const auto ivalue = (*stack)[idx];
    if (!ivalue.isTensor()) {
      continue; // only input that can be aliased is a tensor, not a tensor list (expect in ops without returns)
    }
    const auto tensor = ivalue.toTensor();
    auto* maybe_tensor_wrapper = maybeGetTensorWrapper(tensor);
    if (!maybe_tensor_wrapper || maybe_tensor_wrapper->is_immutable()) {
      // if the input is immutable, we note its relative position in schema, noting that
      // args are in reverse order on stack, so the last arg is at the top of the stack
      const auto relative_pos = idx - (stack->size() - args_size);
      immutable_inputs.push_back(relative_pos);
    }
  }

  // Step 2
  foreachTensorInplace(*stack, stack->size() - args_size, stack->size(), unwrap);

  // See NOTE [grad and vjp interaction with no_grad]
  optional<c10::AutoGradMode> grad_guard;
  if (transform_type == TransformType::Grad && prev_grad_mode.has_value() && *prev_grad_mode == false) {
    grad_guard.emplace(*prev_grad_mode);
  }
  optional<c10::AutoFwGradMode> fw_grad_guard;
  if (transform_type == TransformType::Jvp &&
      prev_fwd_grad_mode.has_value() && prev_fwd_grad_mode.value() == false) {
    fw_grad_guard.emplace(*prev_fwd_grad_mode);
  }

  // Re-dispatch
  if (getDynamicLayerStack().size() == 0) {
    sanityCheckStack(op, stack);
  }

  // Step 4, 5, 6
  auto ret_size = op.schema().returns().size();

  op.callBoxed(stack);

  // lift_fresh: it's must be freshly allocated and should be wrapped. User shouldn't have access to input version
  // alias: this is needed for the CompositeImplicit instance norm (running_mean/var get set to be a wrapped value)
  //        It's not a user facing function, but is more prone to possible errors
  std::vector<int64_t> outputs_aliasing_immutable;
  if (!grad_special_case) {
    outputs_aliasing_immutable = findAliasedOutputs(op.schema(), immutable_inputs);
    // sorting (O(N logN)) lets us avoid an O(N) check for every immutable input (O(N^2))
    std::sort(outputs_aliasing_immutable.begin(), outputs_aliasing_immutable.end());
  }
  // Step 4
  foreachTensorInplaceWithFlag(*stack, stack->size() - ret_size, stack->size(), outputs_aliasing_immutable, wrap);

  // Step 5
  auto args_front = stack->size() - args_size - ret_size;
  for (const auto arg_idx : c10::irange(0, args_size)) {
    auto& ivalue = (*stack)[args_front + arg_idx];
    if (!ivalue.isTensor()) {
      continue;
    }
    auto maybe_tensor_wrapper = maybeGetTensorWrapper(ivalue.toTensor());
    if (!maybe_tensor_wrapper) {
      continue;
    }
    maybe_tensor_wrapper->refreshMetadata();
  }

  // Step 6
  stack->erase(stack->end() - (args_size + ret_size), stack->end() - ret_size);
}

void GradInterpreterPtr::processImpl(
    const c10::OperatorHandle& op,
    torch::jit::Stack* stack) {
  autogradBasedTransformProcess(op, stack, level(), TransformType::Grad);
}

void GradInterpreterPtr::sendToNextInterpreterImpl(
    const c10::OperatorHandle& op,
    torch::jit::Stack* stack,
    bool grad_special_case) {
  autogradBasedTransformSendToNext(
      op, stack, level(),
      TransformType::Grad, prevGradMode(), nullopt, grad_special_case);
}

void JvpInterpreterPtr::processImpl(
    const c10::OperatorHandle& op,
    torch::jit::Stack* stack) {
  autogradBasedTransformProcess(op, stack, level(), TransformType::Jvp);
}

void JvpInterpreterPtr::sendToNextInterpreterImpl(
    const c10::OperatorHandle& op,
    torch::jit::Stack* stack,
    bool grad_special_case) {
  autogradBasedTransformSendToNext(
      op, stack, level(),
      TransformType::Jvp, nullopt, prevFwdGradMode(), grad_special_case);
}

}} // namespace at::functorch
