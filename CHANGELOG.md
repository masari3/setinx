# Changelog

All notable changes to this project will be documented in this file. See [standard-version](https://github.com/conventional-changelog/standard-version) for commit guidelines.

### [1.2.1](///compare/v1.2.0...v1.2.1) (2025-09-07)


### Bug Fixes

* remove duplicate message bd9da6c

## [1.2.0](///compare/v1.1.0...v1.2.0) (2025-09-07)


### Features

* add access and error log nginx 559346d
* add backup host e33c109
* add check php installation 4e20057
* add clickable message a20841c
* add fastcgi param to server block if --php-tcp is flaged 0572ff0
* add flag project name --project-name f0a0a23
* add function backup host, check and test php from fpm, fix file/folder permission c51c7d2
* add function create folder if folder not exist ec03929
* add listen custom port 45f8d3d
* add message info if ssl true 76fd90b
* add message process generating cert with mkcert 489bdda
* add new color 784e71f
* add new finish message when use SSL dd7897c
* add new variable host file and backup 00caeca
* add php socket connection php fpm 819c5ec
* add test file to root directory 3230153
* add text color for output message 47341f3
* add usage example use 5ff9281
* add variable project name e091ba3
* auto detect web root folder 76966a3
* change project name to host 35a3dc0
* ensure log folder exist type macos 2153939
* ssl handling 4be7ea5


### Bug Fixes

* add validation port php fpm f1397ef
* bug checking ssl, mkcert must be installed on system 068b3f0
* bug port tcp 83e9679
* bug typo php sock port b6ae6be
* error port php tcp for php-fpm b39f9cd
* revert docs or usage d90dcb2
* type update vesion 20936b3

## [1.1.0](///compare/v1.0.1...v1.1.0) (2025-09-04)


### Features

* add default root directory e9bb0d6
* add function to scan root directory 6f1cd56

### 1.0.1 (2025-09-04)
1. Cross-platform (macOS + Linux Homebrew)
2. PHP detection (`public/` jika ada)
3. SSL self-signed + redirect HTTP → HTTPS
4. Port default 80/443, bisa override dengan `-p`
5. Remove site (`-d`)
6. `--help/-H` untuk usage