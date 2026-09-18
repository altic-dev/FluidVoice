/*
 *  Copyright 2023 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "api/environment/environment_factory.h"

#include <memory>
#include <utility>

#include "absl/base/nullability.h"
#include "api/environment/deprecated_global_field_trials.h"
#include "api/environment/environment.h"
#include "api/environment/force_test_environment.h"
#include "api/field_trials_view.h"
#include "api/make_ref_counted.h"
#include "api/ref_counted_base.h"
#include "api/rtc_event_log/rtc_event_log.h"
#include "api/scoped_refptr.h"
#include "api/task_queue/default_task_queue_factory.h"
#include "api/task_queue/task_queue_factory.h"
#include "rtc_base/checks.h"
#include "system_wrappers/include/clock.h"

namespace webrtc {
namespace {

template <typename T>
void Store(absl_nonnull std::unique_ptr<T> value,
           scoped_refptr<const RefCountedBase>& leaf) {
  class StorageNode : public RefCountedBase {
   public:
    StorageNode(scoped_refptr<const RefCountedBase> parent,
                absl_nonnull std::unique_ptr<T> value)
        : parent_(std::move(parent)), value_(std::move(value)) {}

    StorageNode(const StorageNode&) = delete;
    StorageNode& operator=(const StorageNode&) = delete;

    ~StorageNode() override = default;

   private:
    scoped_refptr<const RefCountedBase> parent_;
    absl_nonnull std::unique_ptr<T> value_;
  };

  // Utilities provided with ownership form a tree:
  // Root is nullptr, each node keeps an ownership of one utility.
  // Each child node has a link to the parent, but parent is unaware of its
  // children. Each `EnvironmentFactory` and `Environment` keep a reference to a
  // 'leaf_' - node with the last provided utility. This way `Environment` keeps
  // ownership of a single branch of the storage tree with each used utiltity
  // owned by one of the nodes on that branch.
  leaf = make_ref_counted<StorageNode>(std::move(leaf), std::move(value));
}

}  // namespace

EnvironmentFactory::EnvironmentFactory(const Environment& env)
    : leaf_(env.storage_),
      field_trials_(env.field_trials_),
      clock_(env.clock_),
      task_queue_factory_(env.task_queue_factory_),
      event_log_(env.event_log_) {}

void EnvironmentFactory::Set(
    absl_nullable std::unique_ptr<const FieldTrialsView> utility) {
  if (utility != nullptr) {
    field_trials_ = utility.get();
    Store(std::move(utility), leaf_);
  }
}

void EnvironmentFactory::Set(absl_nullable std::unique_ptr<Clock> utility) {
  if (utility != nullptr) {
    clock_ = utility.get();
    Store(std::move(utility), leaf_);
  }
}

void EnvironmentFactory::Set(
    absl_nullable std::unique_ptr<TaskQueueFactory> utility) {
  if (utility != nullptr) {
    task_queue_factory_ = utility.get();
    Store(std::move(utility), leaf_);
  }
}

void EnvironmentFactory::Set(
    absl_nullable std::unique_ptr<RtcEventLog> utility) {
  if (utility != nullptr) {
    event_log_ = utility.get();
    Store(std::move(utility), leaf_);
  }
}

Environment EnvironmentFactory::CreateWithDefaults() && {
  RTC_CHECK((field_trials_ != nullptr && field_trials_->IsTest()) ||
            !IsForceTestEnvironmentEnabled() ||
            IsTestEnvironmentCheckBypassed())
      << "Production Environment creation is not allowed in tests. Use "
         "CreateTestEnvironment.";
  if (field_trials_ == nullptr) {
    Set(std::make_unique<DeprecatedGlobalFieldTrials>());
  }
  if (clock_ == nullptr) {
    Set(Clock::GetRealTimeClock());
  }
  if (task_queue_factory_ == nullptr) {
    Set(CreateDefaultTaskQueueFactory(field_trials_));
  }
  if (event_log_ == nullptr) {
    Set(std::make_unique<RtcEventLogNull>());
  }

  RTC_DCHECK(field_trials_ != nullptr);
  RTC_DCHECK(clock_ != nullptr);
  RTC_DCHECK(task_queue_factory_ != nullptr);
  RTC_DCHECK(event_log_ != nullptr);
  return Environment(std::move(leaf_),  //
                     field_trials_, clock_, task_queue_factory_, event_log_);
}

Environment EnvironmentFactory::Create() const {
  // Create a temporary copy to avoid mutating `this` with default utilities.
  return EnvironmentFactory(*this).CreateWithDefaults();
}

}  // namespace webrtc
