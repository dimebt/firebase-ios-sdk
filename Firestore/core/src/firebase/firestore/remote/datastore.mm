/*
 * Copyright 2018 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "Firestore/core/src/firebase/firestore/remote/datastore.h"

#include <unordered_set>

#include "Firestore/core/include/firebase/firestore/firestore_errors.h"
#include "Firestore/core/src/firebase/firestore/core/database_info.h"
#include "Firestore/core/src/firebase/firestore/remote/grpc_completion.h"
#include "Firestore/core/src/firebase/firestore/util/executor_libdispatch.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "absl/memory/memory.h"
#include "absl/strings/str_cat.h"

namespace firebase {
namespace firestore {
namespace remote {

using core::DatabaseInfo;
using util::internal::Executor;
using util::internal::ExecutorLibdispatch;

namespace {

std::unique_ptr<Executor> CreateExecutor() {
  auto queue = dispatch_queue_create("com.google.firebase.firestore.datastore",
                                     DISPATCH_QUEUE_SERIAL);
  return absl::make_unique<ExecutorLibdispatch>(queue);
}

absl::string_view MakeStringView(grpc::string_ref grpc_str) {
  return {grpc_str.begin(), grpc_str.size()};
}

}  // namespace

Datastore::Datastore(util::AsyncQueue *firestore_queue,
                     const DatabaseInfo &database_info)
    : grpc_connection_{firestore_queue, database_info, &grpc_queue_},
      dedicated_executor_{CreateExecutor()} {
  dedicated_executor_->Execute([this] { PollGrpcQueue(); });
}

void Datastore::Shutdown() {
  grpc_queue_.Shutdown();
  // Drain the executor to make sure it extracted all the operations from gRPC
  // completion queue.
  dedicated_executor_->ExecuteBlocking([] {});
}

void Datastore::PollGrpcQueue() {
  HARD_ASSERT(dedicated_executor_->IsCurrentExecutor(),
              "PollGrpcQueue should only be called on the "
              "dedicated Datastore executor");

  void *tag = nullptr;
  bool ok = false;
  while (grpc_queue_.Next(&tag, &ok)) {
    auto completion = static_cast<GrpcCompletion *>(tag);
    HARD_ASSERT(tag, "gRPC queue returned a null tag");
    completion->Complete(ok);
  }
}

std::unique_ptr<GrpcStream> Datastore::OpenGrpcStream(
    absl::string_view token,
    absl::string_view path,
    GrpcStreamObserver *observer) {
  return grpc_connection_.OpenGrpcStream(token, path, observer);
}

util::Status Datastore::ConvertStatus(grpc::Status from) {
  if (from.ok()) {
    return {};
  }

  grpc::StatusCode error_code = from.error_code();
  HARD_ASSERT(
      error_code >= grpc::CANCELLED && error_code <= grpc::UNAUTHENTICATED,
      "Unknown gRPC error code: %s", error_code);

  return {static_cast<FirestoreErrorCode>(error_code), from.error_message()};
}

std::string Datastore::GetWhitelistedHeadersAsString(
    const GrpcStream::MetadataT& headers) {
  static std::unordered_set<std::string> whitelist = {
      "date", "x-google-backends", "x-google-netmon-label", "x-google-service",
      "x-google-gfe-request-trace"};

  std::string result;

  for (const auto& kv : headers) {
    absl::StrAppend(&result, MakeStringView(kv.first), ": ",
                    MakeStringView(kv.second), "\n");
  }
  return result;
}

}  // namespace remote
}  // namespace firestore
}  // namespace firebase
