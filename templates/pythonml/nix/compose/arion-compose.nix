{
  project.name = "pythonml";
  services.mongo = {
    service = {
      image = "mongo";
      ports = [ "27017:27017" ];
      environment = {
        MONGO_INITDB_ROOT_USERNAME = "admin";
        MONGO_INITDB_ROOT_PASSWORD = "admin";
      };

    };
  };

}
