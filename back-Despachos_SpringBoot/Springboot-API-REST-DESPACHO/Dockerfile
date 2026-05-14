# Etapa 1: Construcción del JAR (Build)
FROM maven:3.9.4-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
# Descarga dependencias para aprovechar caché de Docker
RUN mvn dependency:go-offline -B
COPY src ./src
# Compila el proyecto omitiendo los tests para mayor velocidad
RUN mvn clean package -DskipTests

# Etapa 2: Ejecución de la aplicación (Mínimo Privilegio)
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app

# CREACIÓN DE USUARIO NO ROOT (Buenas prácticas de Seguridad DevOps)
RUN addgroup -S spring && adduser -S spring -G spring
USER spring:spring

# Copia el JAR generado en la Etapa 1
COPY --from=build /app/target/*.jar app.jar

# Exponer el puerto donde corre Spring Boot
EXPOSE 8080

# Comando de inicio
ENTRYPOINT ["java", "-jar", "app.jar"]