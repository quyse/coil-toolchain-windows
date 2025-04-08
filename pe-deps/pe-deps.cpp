#define STRICT
#include <windows.h>
#include <iostream>
#include <queue>
#include <set>
#include <stdexcept>
#include <string>
#include <variant>
#include <vector>


struct NoFileException : public std::runtime_error
{
  NoFileException()
  : std::runtime_error{"no file"}
  {}
};

std::vector<std::string> GetPeDlls(char const* inputFileName)
{
  HANDLE hFile = CreateFileA(inputFileName, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
  if(hFile == INVALID_HANDLE_VALUE)
  {
    if(GetLastError() == ERROR_FILE_NOT_FOUND) throw NoFileException{};
    throw std::runtime_error{"failed to open file"};
  }

  uint64_t fileSize = 0;
  {
    LARGE_INTEGER size = {};
    if(GetFileSizeEx(hFile, &size))
    {
      fileSize = size.QuadPart;
    }
  }

  HANDLE hMapping = CreateFileMappingW(hFile, NULL, PAGE_READONLY, 0, 0, 0);
  CloseHandle(hFile);
  if(!hMapping)
  {
    throw std::runtime_error{"failed to create file mapping"};
  }

  uint8_t const* pFile = (uint8_t const*)MapViewOfFile(hMapping, FILE_MAP_READ, 0, 0, 0);
  CloseHandle(hMapping);
  if(!pFile)
  {
    throw std::runtime_error{"failed to map file"};
  }

  uint64_t offset = 0x3c;
  {
    if(offset + 4 > fileSize)
    {
      throw std::runtime_error{"pe signature offset is out of bounds"};
    }
    offset = *(uint32_t const*)(pFile + offset);
  }

  if(offset + 4 > fileSize)
  {
    throw std::runtime_error{"pe signature is out of bounds"};
  }
  if(memcmp(pFile + offset, "PE\0\0", 4) != 0)
  {
    throw std::runtime_error{"pe signature is wrong"};
  }
  offset += 4;

  if(offset + sizeof(IMAGE_FILE_HEADER) > fileSize)
  {
    throw std::runtime_error{"pe image header is out of bounds"};
  }
  IMAGE_FILE_HEADER const* pHeader = (IMAGE_FILE_HEADER const*)(pFile + offset);
  offset += sizeof(IMAGE_FILE_HEADER);

  if(offset + pHeader->SizeOfOptionalHeader > fileSize)
  {
    throw std::runtime_error{"pe image optional header is out of bounds"};
  }
  IMAGE_OPTIONAL_HEADER const* pGenericOptionalHeader = (IMAGE_OPTIONAL_HEADER const*)(pFile + offset);
  offset += pHeader->SizeOfOptionalHeader;

  std::vector<std::string> imports;

  auto process = [&]<typename OptionalHeader>()
  {
    OptionalHeader const* pOptionalHeader = (OptionalHeader const*)pGenericOptionalHeader;

    if(offset + pHeader->NumberOfSections * sizeof(IMAGE_SECTION_HEADER) > fileSize)
    {
      throw std::runtime_error{"pe image sections are out of bounds"};
    }
    IMAGE_SECTION_HEADER const* pSections = (IMAGE_SECTION_HEADER const*)(pFile + offset);
    offset += pHeader->NumberOfSections * sizeof(IMAGE_SECTION_HEADER);

    IMAGE_DATA_DIRECTORY const& importDirectory = pOptionalHeader->DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    uint8_t const* pImportSection = nullptr;
    IMAGE_IMPORT_DESCRIPTOR const* pImportDescriptors = nullptr;
    for(size_t i = 0; i < pHeader->NumberOfSections; ++i)
    {
      if(importDirectory.VirtualAddress >= pSections[i].VirtualAddress && importDirectory.VirtualAddress + importDirectory.Size <= pSections[i].VirtualAddress + pSections[i].Misc.VirtualSize)
      {
        pImportSection = pFile + pSections[i].PointerToRawData - pSections[i].VirtualAddress;
        pImportDescriptors = (IMAGE_IMPORT_DESCRIPTOR const*)(pImportSection + importDirectory.VirtualAddress);
        break;
      }
    }
    if(!pImportDescriptors)
    {
      throw std::runtime_error{"could not find import section"};
    }

    for(size_t i = 0; (i + 1) * sizeof(IMAGE_IMPORT_DESCRIPTOR) <= importDirectory.Size && pImportDescriptors[i].Name; ++i)
    {
      imports.push_back((char const*)(pImportSection + pImportDescriptors[i].Name));
    }
  };

  switch(pGenericOptionalHeader->Magic)
  {
  case IMAGE_NT_OPTIONAL_HDR32_MAGIC:
    process.operator()<IMAGE_OPTIONAL_HEADER32>();
    break;
  case IMAGE_NT_OPTIONAL_HDR64_MAGIC:
    process.operator()<IMAGE_OPTIONAL_HEADER64>();
    break;
  default:
    throw std::runtime_error{"pe image optional header magic is invalid"};
  }

  return imports;
}

int main(int argc, char** argv)
{
  --argc;
  ++argv;

  std::set<std::string> allImports;
  std::set<std::string> missingImports;
  std::queue<std::string> dllQueue;

  auto processPeImports = [&](char const* inputFileName)
  {
    for(auto const& import : GetPeDlls(inputFileName))
    {
      if(allImports.insert(import).second)
      {
        dllQueue.push(import);
      }
    }
  };

  for(int i = 0; i < argc; ++i)
  {
    processPeImports(argv[i]);
  }

  while(!dllQueue.empty())
  {
    auto import = dllQueue.front();
    dllQueue.pop();

    try
    {
      processPeImports(import.c_str());
    }
    catch(NoFileException const&)
    {
      missingImports.insert(import);
    }
  }

  for(auto const& import : allImports)
  {
    if(missingImports.find(import) == missingImports.end())
    {
      std::cout << import << "\n";
    }
  }

  return 0;
}
