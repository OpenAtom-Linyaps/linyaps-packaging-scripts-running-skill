# linyaps-packaging-scripts-running-skill 新人必看
## 简介
  打包执行Agent, 负责日常打包维护，在已经持有可重复使用的构建工程模板后，接受用户传递的同一个应用的新版本来源(包、仓库)后，根据用户指定的构建工程模板所在目录进行自打包

## 需要安装的依赖包
```bash
python3-yaml python3-ruamel.yaml
linglong-bin=1.13.7-ziggy2 linglong-builder=1.13.7-ziggy2
```

## skills能力介绍
 - `linglong-binary-runner`: 通过 pak_linyaps.sh 自动执行 linyaps 二進制打包。用於已適配便捷打包腳本的項目（特徵：目錄下有 pak_linyaps.sh）。
 - `linglong-source-updater`: 更新已初始化的 linglong.yaml，補充上游源碼信息，更新構建規則，並自動打包為玲瓏 layer。用於 source 類型任務（特徵：目錄下有 linglong.yaml 但缺少 sources 段）。支援 archive/git/file/dsc 四種源碼類型。

## 建议提示词
 - 使用此软件包`https://linux.apps.demo.com/download/demo.deb`更新玲珑应用, 已经适配的工程目录在`/path/to/your/pak_linyaps.sh`
 - 使用此项目源码`https://linux.apps.demo.com/download/demo.orig.tar.xz`更新玲珑应用, 已经适配的工程目录在`/path/to/your/linglong.yaml`