#include <windows.h>
#include <shellapi.h>

#include <filesystem>
#include <string>
#include <vector>

namespace {

std::wstring quoteArgument(const std::wstring& value) {
  if (value.find_first_of(L" \t\"") == std::wstring::npos) return value;
  std::wstring quoted = L"\"";
  size_t slashes = 0;
  for (const wchar_t character : value) {
    if (character == L'\\') {
      ++slashes;
      continue;
    }
    if (character == L'\"') {
      quoted.append(slashes * 2 + 1, L'\\');
      quoted.push_back(L'\"');
      slashes = 0;
      continue;
    }
    quoted.append(slashes, L'\\');
    slashes = 0;
    quoted.push_back(character);
  }
  quoted.append(slashes * 2, L'\\');
  quoted.push_back(L'\"');
  return quoted;
}

std::filesystem::path modulePath() {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                           static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) return {};
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

HANDLE openLog(const std::filesystem::path& path) {
  return CreateFileW(path.c_str(), FILE_APPEND_DATA,
                     FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                     nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
}

int run() {
  int count = 0;
  LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  if (arguments == nullptr) return 10;

  std::wstring home;
  std::wstring instance;
  for (int index = 1; index < count; ++index) {
    const std::wstring argument = arguments[index];
    if (argument == L"--home" && index + 1 < count) {
      home = arguments[++index];
    } else if (argument == L"--service-instance" && index + 1 < count) {
      instance = arguments[++index];
    } else {
      LocalFree(arguments);
      return 11;
    }
  }
  LocalFree(arguments);
  if (home.empty()) return 12;

  const auto launcher = modulePath();
  if (launcher.empty()) return 13;
  const auto agent = launcher.parent_path() / L"sanad.exe";
  if (!std::filesystem::is_regular_file(agent)) return 14;

  const auto logs = std::filesystem::path(home) / L"logs";
  std::error_code error;
  std::filesystem::create_directories(logs, error);
  if (error) return 15;

  if (!SetEnvironmentVariableW(L"SANAD_HOME", home.c_str())) return 16;
  if (!instance.empty() &&
      !SetEnvironmentVariableW(L"SANAD_SERVICE_INSTANCE", instance.c_str())) {
    return 17;
  }

  HANDLE output = openLog(logs / L"daemon.log");
  HANDLE errors = openLog(logs / L"daemon.error.log");
  HANDLE input = CreateFileW(L"NUL", GENERIC_READ,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (output == INVALID_HANDLE_VALUE || errors == INVALID_HANDLE_VALUE ||
      input == INVALID_HANDLE_VALUE) {
    if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
    if (errors != INVALID_HANDLE_VALUE) CloseHandle(errors);
    if (input != INVALID_HANDLE_VALUE) CloseHandle(input);
    return 18;
  }
  SetHandleInformation(output, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  SetHandleInformation(errors, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  SetHandleInformation(input, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  startup.hStdInput = input;
  startup.hStdOutput = output;
  startup.hStdError = errors;

  PROCESS_INFORMATION process{};
  std::wstring command = quoteArgument(agent.wstring()) + L" daemon";
  const DWORD flags = CREATE_NO_WINDOW | CREATE_SUSPENDED;
  const BOOL created = CreateProcessW(
      agent.c_str(), command.data(), nullptr, nullptr, TRUE, flags, nullptr,
      home.c_str(), &startup, &process);
  CloseHandle(input);
  CloseHandle(output);
  CloseHandle(errors);
  if (!created) return 19;

  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  if (job == nullptr) {
    TerminateProcess(process.hProcess, 20);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return 20;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                               sizeof(limits)) ||
      !AssignProcessToJobObject(job, process.hProcess)) {
    TerminateProcess(process.hProcess, 21);
    CloseHandle(job);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return 21;
  }

  ResumeThread(process.hThread);
  CloseHandle(process.hThread);
  WaitForSingleObject(process.hProcess, INFINITE);
  DWORD exitCode = 1;
  GetExitCodeProcess(process.hProcess, &exitCode);
  CloseHandle(process.hProcess);
  CloseHandle(job);
  return static_cast<int>(exitCode);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) { return run(); }
