# Custom Jenkins image, built and pushed to your Docker Hub repo by
# .github/workflows/deploy.yml before every stack deploy. Add plugins
# in plugins.txt; add further customization (config-as-code, base
# packages, etc.) as more RUN/COPY lines below.

FROM jenkins/jenkins:lts-jdk17

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
